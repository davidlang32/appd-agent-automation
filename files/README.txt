Stage AppDynamics Machine Agent bundles (zip) here, e.g.:

  machineagent-bundle-64bit-linux-24.5.0.zip
  machineagent-bundle-64bit-windows-24.5.0.zip

install.yml / upgrade.yml pick the file matching machine_agent_version (set in
inventory/group_vars/machine_agents.yml) and the target OS. Pin
machine_agent_bundle_sha256 in the role defaults to enforce integrity.

This directory is a good candidate for .gitignore (bundles are large binaries).
