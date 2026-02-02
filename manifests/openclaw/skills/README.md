# OpenClaw Skills Setup

This directory contains **optional** skills for OpenClaw agents.

## Quick Start

### Install Moltbook Skill

**Using the install script (easiest):**

```bash
cd /path/to/ocm-guardrails/manifests/openclaw/skills

# Deploy the ConfigMap
oc apply -k .

# Install skill into workspace
./install-moltbook-skill.sh
```

## Why Separate?

Skills are shared resources that can be used by any agent. This separation:
- ✅ Makes skill installation optional and repeatable
- ✅ Allows adding new skills without redeploying core
- ✅ Keeps core deployment minimal
- ✅ Skills are loaded from `~/.openclaw/skills/` via config

## Directory Structure

```
skills/
├── kustomization.yaml          # Generates ConfigMaps from SKILL.md files
├── install-moltbook-skill.sh   # Install script
├── moltbook/
│   └── SKILL.md                # Moltbook API skill (standalone file)
└── README.md                   # This file
```

**Note**: SKILL.md files are maintained as standalone files, not embedded in YAML. Kustomize's `configMapGenerator` creates the ConfigMaps automatically.

---

## Adding New Skills

### Method 1: Using Kustomize (Recommended)

1. Create a new subdirectory with your skill:
   ```bash
   mkdir -p myskill/
   ```

2. Create the SKILL.md file:
   ```bash
   cat > myskill/SKILL.md << 'EOF'
   ---
   name: myskill
   description: My custom skill
   metadata: { "openclaw": { "emoji": "🔧" } }
   ---

   # My Custom Skill

   Skill content goes here...
   EOF
   ```

3. Update `kustomization.yaml` to include your skill:
   ```yaml
   configMapGenerator:
     - name: moltbook-skill
       files:
         - moltbook/SKILL.md
       options:
         labels:
           app: openclaw
           skill: moltbook
         disableNameSuffixHash: true
     - name: myskill-skill
       files:
         - myskill/SKILL.md
       options:
         labels:
           app: openclaw
           skill: myskill
         disableNameSuffixHash: true
   ```

4. Deploy ConfigMap:
   ```bash
   oc apply -k .
   ```

5. Copy to workspace:
   ```bash
   POD=$(oc get pods -n openclaw -l app=openclaw -o jsonpath='{.items[0].metadata.name}')
   oc get configmap myskill-skill -n openclaw -o jsonpath='{.data.SKILL\.md}' | \
     oc exec -i -n openclaw $POD -c gateway -- sh -c 'mkdir -p ~/.openclaw/skills/myskill && cat > ~/.openclaw/skills/myskill/SKILL.md && chmod -R 775 ~/.openclaw/skills'
   ```

---

## Editing Skills

To update a skill:

1. Edit the SKILL.md file directly:
   ```bash
   vim moltbook/SKILL.md
   ```

2. Regenerate the ConfigMap:
   ```bash
   oc apply -k .
   ```

3. Copy to workspace:
   ```bash
   ./install-moltbook-skill.sh
   ```

4. Restart the gateway to pick up changes (if needed):
   ```bash
   oc rollout restart deployment/openclaw -n openclaw
   ```

---

## File Structure in OpenClaw Home

After skills setup, the openclaw-home PVC contains:

```
/home/node/.openclaw/
├── workspace/           # shadowman default workspace
├── workspace-philbot/   # philbot workspace
├── workspace-techbot/   # techbot workspace
├── workspace-poetbot/   # poetbot workspace
├── workspace-adminbot/  # adminbot workspace
└── skills/
    └── moltbook/
        └── SKILL.md
```

## Summary

Skills provide reusable capabilities that any agent can use. The Moltbook skill enables agents to:
- Post to Moltbook social network
- Comment on posts
- Vote on content
- Follow other agents
- Search and browse feeds

After installation, all agents with the skill loaded can autonomously interact with Moltbook!

For agent-specific setup (registration, roles, cron jobs), see [../agents/README.md](../agents/README.md).
