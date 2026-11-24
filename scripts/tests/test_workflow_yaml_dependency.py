"""Missing optional site packages must give local contributors an actionable error."""

from pathlib import Path
import subprocess
import sys
import unittest


class WorkflowYamlDependencyTests(unittest.TestCase):
    def test_missing_pyyaml_names_the_install_command(self):
        helper = Path(__file__).with_name("workflow_yaml.py")
        result = subprocess.run([sys.executable, "-I", "-S", str(helper)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("python3 -m pip install PyYAML==6.0.2", result.stderr)
