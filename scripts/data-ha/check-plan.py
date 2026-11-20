"""Reject deletion/replacement of data nodes from an already exported Terraform plan."""
import json
import sys
from pathlib import Path


def rejected_changes(plan):
    if not isinstance(plan, dict) or not isinstance(plan.get("resource_changes"), list):
        raise ValueError("Expected Terraform show -json with resource_changes")
    rejected = []
    for resource in plan["resource_changes"]:
        if not isinstance(resource, dict) or not isinstance(resource.get("address"), str):
            raise ValueError("Invalid resource change entry")
        address = resource["address"]
        if not address.startswith("module.data_compute."):
            continue
        actions = resource.get("change", {}).get("actions")
        if not isinstance(actions, list) or not actions or not all(isinstance(action, str) for action in actions):
            raise ValueError("Missing actions for data resource: " + address)
        if "delete" in actions or any(action not in {"create", "update", "read", "no-op"} for action in actions):
            rejected.append((address, actions))
    return rejected


def main():
    if len(sys.argv) != 2:
        print("Usage: python scripts/data-ha/check-plan.py plan.json", file=sys.stderr)
        return 2
    try:
        plan = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
        rejected = rejected_changes(plan)
    except (OSError, ValueError, TypeError, AttributeError) as error:
        print("Plan review failed: " + str(error), file=sys.stderr)
        return 2
    for address, actions in rejected:
        # Only addresses/actions are printed; plan values may contain secrets.
        print("Rejected: " + address + " " + ",".join(actions), file=sys.stderr)
    if rejected:
        return 1
    print("No data-resource deletion or replacement found. Runtime/configuration review is still required.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
