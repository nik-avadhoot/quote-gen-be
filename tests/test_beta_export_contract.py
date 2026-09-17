"""BR-5 server-side beta mark contract."""
import pathlib
import sys

SOURCE = (pathlib.Path(__file__).resolve().parents[1] / "server.py").read_text(encoding="utf-8")
PASSES, FAILURES = 0, []


def check(condition, label):
    global PASSES
    if condition:
        PASSES += 1
        print(f"ok   - {label}")
    else:
        FAILURES.append(label)
        print(f"FAIL - {label}")


check('beta_export     = data.get("beta") is True' in SOURCE,
      "BR-5-BE-1 only an exact JSON boolean requests beta marking")
check('ws_cbb["D4"] = f"BETA | {reference_line}" if beta_export else reference_line' in SOURCE,
      "BR-5-BE-2 the returned master template visibly carries BETA in its reference line")

print(f"\n{PASSES} passed, {len(FAILURES)} failed")
if FAILURES:
    sys.exit(1)
print("BR-5 server beta export contract PASS")
