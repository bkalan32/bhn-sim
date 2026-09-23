"""
Laptop entry point for the load generator (12-loadgen.sh, 33-loadgen-egift.sh).

Day 21: the generator itself moved to services/loadgen/loadgen.py, where the pipeline builds
it into the `loadgen` Deployment. This file runs that same code with the same flags
(--url, --rps, --payload), so there is one generator, not two copies drifting apart.
"""
import os
import runpy
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.argv[0] = "loadgen"
runpy.run_path(os.path.join(HERE, "..", "services", "loadgen", "loadgen.py"), run_name="__main__")
