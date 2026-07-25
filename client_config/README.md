# client_config/

Per-contract, proprietary settings live here and are **never committed** (see
`.gitignore`). Only `example.client.yml` is tracked.

## Use

```bash
cp client_config/example.client.yml client_config/<client>.yml
# edit with the client's real controller/email/report values
ansible-playbook playbooks/site.yml -e @client_config/<client>.yml -e appd_action=configure
```

Secrets (access keys, SMTP password) stay in Ansible Vault and are referenced by
name from the client file (e.g. `{{ vault_appd_access_key }}`).

## Porting to a new contract

Hand over the repo **without** your `client_config/<client>.yml`. The new team
copies the example, fills in their own values, and they're running — no
proprietary detail from any prior client travels with the project.
