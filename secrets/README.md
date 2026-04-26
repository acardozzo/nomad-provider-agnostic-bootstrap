# Encrypted secrets (sops + age)

This directory holds **encrypted** files committed to git. Decryption requires
an age private key set via `SOPS_AGE_KEY_FILE`.

## One-time operator setup

```bash
brew install sops age              # macOS
# or: apt install age && curl -L https://github.com/getsops/sops/releases/...

mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt

# Note the public key it printed (starts with "age1...") and add it to .sops.yaml:
export SOPS_AGE_RECIPIENTS="age1xxxxxxxx,age1yyyyyyyy"   # comma-separated
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
```

Bake those exports into your shell profile.

## Committing a secret

```bash
# Plaintext file (never commit this)
cat > /tmp/cluster.yaml <<EOF
vultr_api_key: "..."
linode_token: "..."
ssh_public_key: "ssh-ed25519 AAAA..."
EOF

# Encrypt and commit the encrypted version
sops --encrypt /tmp/cluster.yaml > secrets/cluster.yaml
git add secrets/cluster.yaml
git commit -m "chore(secrets): add cluster credentials"
shred -u /tmp/cluster.yaml      # or rm
```

## Using a secret at apply time

`bin/apply` reads `secrets/cluster.yaml` if present, decrypts on the fly, and
exports the variables. Same for `bin/bootstrap`.

Multiple operators? Add their public age keys to `.sops.yaml` recipients and
run `sops updatekeys secrets/cluster.yaml` to re-wrap.
