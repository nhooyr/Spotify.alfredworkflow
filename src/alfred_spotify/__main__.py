import json
import sys


def main():
    # The launcher can be called by a Python older than the project minimum.
    if sys.version_info < (3, 14):  # noqa: UP036
        message = "Python 3.14 or newer is required. Install it with: brew install python"
        if len(sys.argv) > 1 and sys.argv[1] == "resident":
            print(json.dumps({"type": "error", "message": message}), flush=True)
            return
        print(
            json.dumps(
                {
                    "variables": {"status_text": message},
                    "update": {
                        "ids": {
                            "status": {"text": "{var:status_text}"},
                            "now_title": {"text": "Install Python 3.14 or newer"},
                        }
                    },
                }
            )
        )
        return
    if len(sys.argv) > 1 and sys.argv[1] == "resident":
        from .resident import run
    else:
        from .controller import main as run
    run()


if __name__ == "__main__":
    main()
