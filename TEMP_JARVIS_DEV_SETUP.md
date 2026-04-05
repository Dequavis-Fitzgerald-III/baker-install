# TEMP_JARVIS_DEV_SETUP.md

> ⚠️ This file is temporary. Delete it when Jarvis moves to the server/Docker setup.
> These steps are just to get back to where you were developing Jarvis on nomadbaker.

---

## What this is

A one-time checklist to get the Jarvis dev environment running on nomadbaker after a fresh install. These steps are intentionally **not** part of the install script because they're specific to the current dev phase, not a permanent part of the machine setup.

---

## Steps

### 1. Create the Python virtual environment

```bash
mkdir -p ~/.venvs
python -m venv ~/.venvs/jarvis
```

### 2. Clone the Jarvis repo

```bash
mkdir -p ~/projects
git clone <your-jarvis-repo-url> ~/projects/jarvis
```

> Replace `<your-jarvis-repo-url>` with the actual repo URL.

### 3. Install dependencies

```bash
source ~/.venvs/jarvis/bin/activate
cd ~/projects/jarvis
pip install -r requirements.txt
```

### 4. Pull ollama models

```bash
# Pull the models you were using for Jarvis development
# Replace the model names below with the ones you were actually using
ollama pull <model-name>

# e.g:
# ollama pull llama3
# ollama pull mistral
# ollama pull codellama
```

> Fill in the actual model names you were using before the reinstall.

### 5. Update the jarvis alias

The post-install script added a placeholder `jarvis` alias to `~/.bashrc`. It points to the local venv which is now set up — so it should work as-is:

```bash
alias jarvis="source ~/.venvs/jarvis/bin/activate && cd ~/projects/jarvis && python main.py"
```

Reload your shell to pick it up:

```bash
source ~/.bashrc
```

Then test it:

```bash
jarvis
```

---

## What to do when Jarvis moves to the server

1. Update the `jarvis` alias in your dotfiles `.bashrc` to point to the server instead
2. Delete this file from the repo
3. The venv and local clone on nomadbaker can be removed

---
