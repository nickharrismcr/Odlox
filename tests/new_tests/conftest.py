import sys, os, pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GLOX      = os.path.join(REPO_ROOT, "bin", "odlox.exe")


def pytest_configure(config):
    if not os.environ.get("LOX_PATH"):
        os.environ["LOX_PATH"] = REPO_ROOT


def pytest_collection_modifyitems(items):
    if not os.path.exists(GLOX):
        skip = pytest.mark.skip(reason="bin/odlox.exe not built — run: odin build src -out:bin/odlox.exe")
        for item in items:
            item.add_marker(skip)
