// bhn-sim deploy pipeline.
//
// Five stages, five things a pipeline owes an on-call engineer:
//   Test     no broken unit means no deploy. Cheap and first.
//   Build    image tagged with the build number: "what version is running" is one kubectl away.
//   Deploy   apply the manifest with the new tag, record WHY, wait for healthy, stamp Grafana.
//   Verify   wait, ask Prometheus, fail the build if the error rate is bad.
//   post     if Verify failed, roll back automatically and say so.
//
// Differences from the PDF's version are marked FIX: and explained in CORRECTIONS-DAY6.md.

pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  parameters {
    choice(name: 'SERVICE', choices: ['activation', 'egift'], description: 'Service to deploy')
    string(name: 'CHANGE_CAUSE', defaultValue: 'routine release', description: 'Why this deploy is happening (goes into rollout history and the Grafana annotation)')
    string(name: 'ERROR_THRESHOLD', defaultValue: '10', description: 'Fail Verify if post-deploy error rate (%) exceeds this OR 3x the pre-deploy baseline')
  }

  environment {
    NS      = 'payments'
    IMAGE   = "${params.SERVICE}:${env.BUILD_NUMBER}"
    // FIX: the PDF hardcodes activation_requests_total and admits egift breaks. Map it.
    METRIC  = "${params.SERVICE == 'egift' ? 'egift_orders_total' : 'activation_requests_total'}"
    // Prometheus and Grafana via the API server's service proxy: works from anywhere
    // kubectl works, no helper pods, no cluster DNS needed from the Jenkins container.
    PROM_PROXY = '/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy'
  }

  stages {
    stage('Checkout') {
      steps {
        // /repo is your WSL working tree, bind-mounted. Clone = what is COMMITTED on
        // the current branch. Uncommitted edits do not deploy. That is a feature.
        sh 'rm -rf src && git clone -q /repo src && cd src && git log -1 --format="deploying %h  %s"'
      }
    }

    stage('Test') {
      steps {
        dir("src/services/${params.SERVICE}") {
          sh '''
            python3 -m venv .venv
            . .venv/bin/activate
            pip install -q --upgrade pip
            pip install -q -r requirements.txt
            [ -f requirements-dev.txt ] && pip install -q -r requirements-dev.txt
            grep -q opentelemetry-distro requirements.txt && opentelemetry-bootstrap -a install -q 2>/dev/null || true
            # FIX: the Dockerfile COPYs requirements.lock.txt, which is generated, not
            # committed. Freeze it here from the tested venv so Build has it.
            pip freeze > requirements.lock.txt
            if [ -d tests ]; then python -m pytest -q tests/; else echo "no tests dir — skipping"; fi
          '''
        }
      }
    }

    stage('Build') {
      steps {
        dir("src/services/${params.SERVICE}") {
          sh "docker build --build-arg APP_VERSION=${env.BUILD_NUMBER} -t ${IMAGE} ."
          sh "kind load docker-image ${IMAGE} --name bhn-sim"
        }
      }
    }

    stage('Deploy') {
      steps {
        script {
          // Pre-deploy baseline, so Verify can compare rather than only use a fixed line.
          env.BASELINE_ERR = promErrorRate()
          echo "Pre-deploy error rate: ${env.BASELINE_ERR}%"
        }
        // FIX: apply the MANIFEST with the tag substituted, not `kubectl set image`.
        // set image leaves the repo saying one thing and the cluster another (Day 3, B6).
        // Applying the manifest keeps every env var and probe in step with the file.
        sh """
          sed "s|image: ${params.SERVICE}:.*|image: ${IMAGE}|" src/k8s/${params.SERVICE}.yaml | kubectl -n ${NS} apply -f -
          kubectl -n ${NS} annotate deployment/${params.SERVICE} kubernetes.io/change-cause="build ${BUILD_NUMBER}: ${params.CHANGE_CAUSE}" --overwrite
          kubectl -n ${NS} rollout status deployment/${params.SERVICE} --timeout=180s
        """
        script { grafanaAnnotate("deploy", "build ${env.BUILD_NUMBER}: ${params.CHANGE_CAUSE}") }
      }
    }

    stage('Verify') {
      steps {
        script {
          echo "Waiting 120s for the 2m rate window to fill with post-deploy traffic..."
          sleep 120
          def err = promErrorRate()
          echo "Post-deploy error rate: ${err}%  (baseline ${env.BASELINE_ERR}%)"
          if (err == 'nodata') {
            env.VERIFY_FAILED = 'true'
            error("No traffic reached ${params.SERVICE} after deploy — treating as failed")
          }
          def e = err.toFloat()
          def b = (env.BASELINE_ERR == 'nodata') ? 0.0 : env.BASELINE_ERR.toFloat()
          def limit = Math.max(params.ERROR_THRESHOLD.toFloat(), 3 * b)
          if (e > limit) {
            // FIX: a flag set here, not env.STAGE_NAME in post{} — the PDF's own
            // troubleshooting notes that STAGE_NAME is unreliable there.
            env.VERIFY_FAILED = 'true'
            error("Error rate ${e}% exceeds limit ${limit}% (threshold ${params.ERROR_THRESHOLD}%, 3x baseline ${3*b}%)")
          }
        }
      }
    }
  }

  post {
    failure {
      script {
        if (env.VERIFY_FAILED == 'true') {
          echo "Verify failed — rolling back ${params.SERVICE}"
          sh "kubectl -n ${NS} rollout undo deployment/${params.SERVICE}"
          sh "kubectl -n ${NS} rollout status deployment/${params.SERVICE} --timeout=180s"
          sh "kubectl -n ${NS} annotate deployment/${params.SERVICE} kubernetes.io/change-cause=\"AUTO-ROLLBACK of build ${BUILD_NUMBER}: ${params.CHANGE_CAUSE}\" --overwrite"
          grafanaAnnotate("rollback", "AUTO-ROLLBACK build ${env.BUILD_NUMBER}: ${params.CHANGE_CAUSE}")
          echo "ROLLED BACK ${params.SERVICE} to previous revision"
        } else {
          echo "Build failed before Verify — nothing was deployed, nothing to roll back"
        }
      }
    }
  }
}

// ---- helpers ------------------------------------------------------------------

// Error rate over the last 2 minutes, as a string percentage, or 'nodata'.
// Uses the API server's service proxy, so no helper pod is needed.
def promErrorRate() {
  def q = java.net.URLEncoder.encode(
    "100 * sum(rate(${env.METRIC}{status=\"error\"}[2m])) / clamp_min(sum(rate(${env.METRIC}[2m])), 0.001)", "UTF-8")
  def raw = sh(returnStdout: true, script: "kubectl get --raw '${env.PROM_PROXY}/api/v1/query?query=${q}'").trim()
  // FIX: parse with a real JSON reader, not a regex. Empty result -> 'nodata', not a
  // Groovy NullPointerException inside the post{} block.
  def v = sh(returnStdout: true, script: """python3 -c 'import json,sys
d=json.loads(sys.argv[1]).get("data",{}).get("result",[])
print("nodata" if not d else "%.2f" % float(d[0]["value"][1]))' '${raw.replace("'", "")}'""").trim()
  return v
}

// Vertical line on every dashboard that has the "deploy" annotation query (all of ours do).
def grafanaAnnotate(String tag, String text) {
  // FIX: the PDF fetches the Grafana password INSIDE a kubectl-run pod that has no
  // kubectl -> 401. Fetch it here, on the agent, then exec into the Grafana pod which
  // has curl and can reach itself on localhost.
  def pw = sh(returnStdout: true, script: "kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d").trim()
  def body = groovy.json.JsonOutput.toJson([tags: [tag, params.SERVICE], text: text])
  def rc = sh(returnStatus: true, script: """
    kubectl -n monitoring exec deploy/kps-grafana -c grafana -- \\
      curl -sf -u 'admin:${pw}' -H 'Content-Type: application/json' \\
      -X POST http://localhost:3000/api/annotations -d '${body}' >/dev/null
  """)
  if (rc != 0) { echo "WARNING: Grafana annotation failed (rc=${rc}) — deploy continues" }
}
