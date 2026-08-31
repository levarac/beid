import sys

print("fake stdout: compile noise")
print("fake stderr: stack detail", file=sys.stderr)
raise SystemExit(int(sys.argv[1]))
