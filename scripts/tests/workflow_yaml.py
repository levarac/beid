"""Read workflow structure with the YAML parser already installed by PR CI."""

try:
    import yaml
except ModuleNotFoundError as error:
    if error.name != "yaml":
        raise
    raise SystemExit("Script tests require PyYAML; install it with: "
                     "python3 -m pip install PyYAML==6.0.2") from error


def workflow_data(text):
    # BaseLoader keeps scalar spellings (including Actions' `on`) as strings.
    # SafeLoader's YAML 1.1 boolean resolver otherwise turns `on` into True.
    # Assertions below compare scalar values explicitly rather than relying on
    # Python truthiness, so `false` cannot accidentally become a true condition.
    return yaml.load(text, Loader=yaml.BaseLoader)


def named_step(data, job, name):
    matches = [step for step in data["jobs"][job]["steps"] if step.get("name") == name]
    assert len(matches) == 1, f"expected one {job}/{name}, found {len(matches)}"
    return matches[0]
