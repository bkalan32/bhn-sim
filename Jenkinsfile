// bhn-sim deploy pipeline.
//
// Day 8: SERVICE now covers all four workloads. KIND (deployment|cronjob) and METRIC
// (request counter or empty) decide how Deploy, Verify and rollback behave — see the
// Verify stage. CORRECTIONS-DAY8.md B6 explains why the PDF's "ship both through the
// pipeline" did not work as written.
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
    choice(name: 'SERVICE', choices: ['activation', 'egift', 'incident-bot', 'settlement', 'remediator', 'loadgen', 'mission-control'], description: 'Service to deploy (Day 8: incident-bot is a Deployment with no traffic metric; settlement is a CronJob; Day 12: remediator; Day 21: loadgen — one Deployment, two containers, verified like the bot; mission-control — the control plane)')
    string(name: 'CHANGE_CAUSE', defaultValue: 'routine release', description: 'Why this deploy is happening (goes into rollout history and the Grafana annotation)')
    string(name: 'ERROR_THRESHOLD', defaultValue: '10', description: 'Fail Verify if post-deploy error rate (%) exceeds this OR 3x the pre-deploy baseline')
    // Day 12, tier-2 drill ONLY: ship a bad release WITHOUT the pipeline's safety net, so the
    // incident path (alert -> remediator proposal -> human approval -> rollback) is what
    // recovers production. Never true for a real release; the build log shouts when it is.
    booleanParam(name: 'SKIP_VERIFY', defaultValue: false, description: 'DRILL ONLY (Day 12): skip Verify and its auto-rollback')
  }

  environment {
    NS      = 'payments'
    IMAGE   = "${params.SERVICE}:${env.BUILD_NUMBER}"
    // FIX: the PDF hardcodes activation_requests_total and admits egift breaks. Map it.
    // Day 8: services with no request metric get an empty METRIC and a different Verify.
    METRIC  = "${params.SERVICE == 'egift' ? 'egift_orders_total' : params.SERVICE == 'activation' ? 'activation_requests_total' : ''}"
    // Day 8: settlement is a CronJob. No rollout, no undo — Deploy and rollback differ.
    KIND    = "${params.SERVICE == 'settlement' ? 'cronjob' : 'deployment'}"
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
            # INC-0006's follow-up: tests cover the amounts production sees (ungated since
            # Day 8). The velocity-check release fails HERE, before anything is built.
            if [ -d tests ]; then python -m pytest -q tests/; else echo "no tests dir — skipping"; fi
          '''
        }
      }
    }

    stage('Build') {
      steps {
        dir("src/services/${params.SERVICE}") {
          // Day 21 (CORRECTIONS-DAY21 B4): a build shares the 8 CPUs with the cluster it deploys
          // to; uncapped, pip + layer export starved the control plane into losing its leader
          // leases. Two CPUs: the build takes a little longer, the platform stays up.
          sh "docker build --cpu-period=100000 --cpu-quota=200000 --build-arg APP_VERSION=${env.BUILD_NUMBER} -t ${IMAGE} ."
          sh "kind load docker-image ${IMAGE} --name bhn-sim"
        }
      }
    }

    stage('Deploy') {
      steps {
        script {
          // Pre-deploy baseline, so Verify can compare rather than only use a fixed line.
          env.BASELINE_ERR = env.METRIC ? promErrorRate() : 'n/a'
          echo "Pre-deploy error rate: ${env.BASELINE_ERR}%"
          // Remember what is running now: a CronJob has no rollout history to undo to.
          def imgPath = (env.KIND == 'cronjob') ? '.spec.jobTemplate.spec.template.spec.containers[0].image' : '.spec.template.spec.containers[0].image'
          env.PREV_IMAGE = sh(returnStdout: true, script: "kubectl -n ${NS} get ${env.KIND}/${params.SERVICE} -o jsonpath='{${imgPath}}' 2>/dev/null || true").trim()
          echo "Currently running: ${env.PREV_IMAGE ?: '(nothing — first deploy)'}"
        }
        // FIX: apply the MANIFEST with the tag substituted, not `kubectl set image`.
        // set image leaves the repo saying one thing and the cluster another (Day 3, B6).
        // Applying the manifest keeps every env var and probe in step with the file.
        sh """
          sed "s|image: ${params.SERVICE}:.*|image: ${IMAGE}|" src/k8s/${params.SERVICE}.yaml | kubectl -n ${NS} apply -f -
          kubectl -n ${NS} annotate ${KIND}/${params.SERVICE} kubernetes.io/change-cause="build ${BUILD_NUMBER}: ${params.CHANGE_CAUSE}" --overwrite
        """
        script {
          // Day 17 B10: from here the cluster HAS the new spec. If the rollout never becomes
          // ready (image missing a module, probe never passing) the old pod is already gone
          // under strategy Recreate — the post block must roll back, not say "nothing deployed".
          env.APPLIED = 'true'
          if (env.KIND == 'deployment') {
            sh "kubectl -n ${NS} rollout status deployment/${params.SERVICE} --timeout=180s"
          } else {
            echo "CronJob updated — future runs use ${IMAGE}. Verify triggers one now."
          }
          env.DEPLOYED = 'true'
          grafanaAnnotate("deploy", "build ${env.BUILD_NUMBER}: ${params.CHANGE_CAUSE}")
          if (params.SKIP_VERIFY) {
            echo "!!!!!!!!!!  SKIP_VERIFY=true: NO Verify, NO auto-rollback. The remediator + a human approval is the safety net now (Day 12 drill).  !!!!!!!!!!"
          }
        }
      }
    }

    stage('Verify') {
      when { expression { !params.SKIP_VERIFY } }
      steps {
        script {
          // Day 8: three kinds of verification, because "did the deploy work?" means
          // something different for each shape of workload.
          if (env.KIND == 'cronjob') {
            // A batch job is verified by RUNNING it. Exit 0 within the deadline = good.
            def job = "${params.SERVICE}-ci-${env.BUILD_NUMBER}"
            sh "kubectl -n ${NS} create job ${job} --from=cronjob/${params.SERVICE}"
            // A failed Job never reaches condition=complete, so a crash on the new image
            // surfaces here as the 180s timeout (backoffLimit 1 = two attempts inside it).
            def rc = sh(returnStatus: true, script: "kubectl -n ${NS} wait --for=condition=complete job/${job} --timeout=180s")
            sh "kubectl -n ${NS} logs job/${job} || true"
            if (rc != 0) {
              env.VERIFY_FAILED = 'true'
              error("Job ${job} did not complete successfully on ${IMAGE}")
            }
            echo "Job ${job} completed on ${IMAGE}"
            return
          }
          if (!env.METRIC) {
            // No traffic metric (incident-bot): healthy = still Ready after 30s and no
            // container restarts on the new pods. A crash loop shows up here.
            sleep 30
            sh "kubectl -n ${NS} rollout status deployment/${params.SERVICE} --timeout=60s"
            def restarts = sh(returnStdout: true, script: "kubectl -n ${NS} get pods -l app=${params.SERVICE} -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}'").trim()
            echo "Container restarts on new pods: '${restarts}'"
            // Plain loop, not .any{} — closures on Java arrays are a sandbox/CPS lottery.
            for (String r : restarts.split(' ')) {
              if (r && r != '0') {
                env.VERIFY_FAILED = 'true'
                error("New ${params.SERVICE} pods are restarting (${restarts}) — treating as failed")
              }
            }
            return
          }
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
          // Jenkins' Groovy sandbox rejects java.lang.Math.max (and most Java statics)
          // unless an admin approves it. A comparison needs no approval.
          def t = params.ERROR_THRESHOLD.toFloat()
          def limit = (t > 3 * b) ? t : 3 * b
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
          if (env.KIND == 'deployment' && !env.PREV_IMAGE) {
            // Rebuild (CORRECTIONS-REBUILD B6): a FIRST deploy has no revision to undo to —
            // `rollout undo` died with "no rollout history found" and a stack trace. Say so,
            // leave the new pods in place (they are the only copy), and fail the build.
            echo "FIRST DEPLOY of ${params.SERVICE}: there is no previous revision to roll back to. Build ${env.BUILD_NUMBER} is LEFT RUNNING."
            echo "  Usual cause on a first deploy: no traffic yet (start the load generator, then deploy again)."
            echo "  To remove it instead: kubectl -n ${NS} delete deployment/${params.SERVICE}"
            return
          }
          if (env.KIND == 'deployment') {
            sh "kubectl -n ${NS} rollout undo deployment/${params.SERVICE}"
            sh "kubectl -n ${NS} rollout status deployment/${params.SERVICE} --timeout=180s"
          } else if (env.PREV_IMAGE) {
            // No rollout history for a CronJob: re-apply the manifest with the image
            // that was running before this build.
            sh "sed 's|image: ${params.SERVICE}:.*|image: ${env.PREV_IMAGE}|' src/k8s/${params.SERVICE}.yaml | kubectl -n ${NS} apply -f -"
          } else {
            echo "No previous image recorded — nothing to roll the CronJob back to"
          }
          sh "kubectl -n ${NS} annotate ${KIND}/${params.SERVICE} kubernetes.io/change-cause=\"AUTO-ROLLBACK of build ${BUILD_NUMBER}: ${params.CHANGE_CAUSE}\" --overwrite"
          grafanaAnnotate("rollback", "AUTO-ROLLBACK build ${env.BUILD_NUMBER}: ${params.CHANGE_CAUSE}")
          echo "ROLLED BACK ${params.SERVICE} to ${env.PREV_IMAGE ?: 'previous revision'}"
        } else if (env.APPLIED == 'true' && env.KIND == 'deployment' && !env.PREV_IMAGE) {
          echo "FIRST DEPLOY of ${params.SERVICE} never became ready, and there is no previous revision to roll back to."
          echo "  Read the failing pod: kubectl -n ${NS} describe pod -l app=${params.SERVICE}; kubectl -n ${NS} logs -l app=${params.SERVICE} --previous"
        } else if (env.APPLIED == 'true' && env.KIND == 'deployment') {
          // Day 17 B10: applied, but the rollout never became ready. The service is DOWN
          // (Recreate). Roll back to the previous revision and prove it is serving.
          echo "Rollout of build ${env.BUILD_NUMBER} never became ready — rolling back ${params.SERVICE}"
          sh "kubectl -n ${NS} rollout undo deployment/${params.SERVICE}"
          sh "kubectl -n ${NS} rollout status deployment/${params.SERVICE} --timeout=180s"
          sh "kubectl -n ${NS} annotate ${KIND}/${params.SERVICE} kubernetes.io/change-cause=\"AUTO-ROLLBACK of build ${BUILD_NUMBER} (rollout never ready): ${params.CHANGE_CAUSE}\" --overwrite"
          grafanaAnnotate("rollback", "AUTO-ROLLBACK build ${env.BUILD_NUMBER} (rollout never ready): ${params.CHANGE_CAUSE}")
          echo "ROLLED BACK ${params.SERVICE} — the new pod never passed readiness; see 'kubectl logs --previous' on the failed pod above"
        } else if (env.DEPLOYED == 'true') {
          echo "WARNING: build ${env.BUILD_NUMBER} WAS deployed but Verify errored before reaching a verdict."
          echo "It has NOT been rolled back. Check the dashboard now; roll back by hand if needed:"
          echo "  kubectl -n ${NS} rollout undo deployment/${params.SERVICE}   (or re-apply k8s/${params.SERVICE}.yaml for the CronJob)"
        } else {
          echo "Build failed before Deploy — nothing was deployed, nothing to roll back"
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
  // The password travels in an env var with `set +x`, so it never appears in the build
  // log. Jenkins echoes every sh command line by default — a secret on the command line
  // is a secret in the log.
  // Day 18 (CORRECTIONS-DAY18 B8): the password moved to secret/grafana-admin on Day 13 (B10)
  // and this line kept reading the chart's secret — every deploy since wrote NO annotation,
  // behind a WARNING that "continues". Ours first, the chart's as a fallback, same as lib.sh.
  def pw = sh(returnStdout: true, script: "set +x; kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || kubectl -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d").trim()
  def body = groovy.json.JsonOutput.toJson([tags: [tag, params.SERVICE], text: text])
  def rc = 1
  withEnv(["GRAFANA_PW=${pw}", "ANN_BODY=${body}"]) {
    rc = sh(returnStatus: true, script: '''set +x
      kubectl -n monitoring exec deploy/kps-grafana -c grafana -- \\
        curl -sf -u "admin:$GRAFANA_PW" -H 'Content-Type: application/json' \\
        -X POST http://localhost:3000/api/annotations -d "$ANN_BODY" >/dev/null''')
  }
  if (rc != 0) {
    // Day 18: an annotation that fails is a change the bot, the remediator and the KB will
    // never see. Still not a reason to fail a deploy — but it is a reason to SHOUT.
    echo "!!!!!!!!!!  Grafana annotation FAILED (rc=${rc}): this ${tag} is INVISIBLE to the incident bot's deploys collector and the remediator's post-deploy signature. Fix before the next release: kubectl -n monitoring get secret grafana-admin  !!!!!!!!!!"
  }
}
