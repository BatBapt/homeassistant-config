# French Home Assistant Voice Assistant

A fully local, French-language voice assistant built on Home Assistant, split
across a Raspberry Pi (Home Assistant core, wake word, microphone/speaker
satellite, text-to-speech) and a Windows PC with a GPU (speech-to-text and the
local LLM conversation agent). No cloud service is involved in the voice
pipeline.

The Home Assistant configuration, custom sentences and voice intents are all
in French. This document is in English; example voice commands and YAML
content are in French as they appear in the repository.

> Security notice: this repository is public. Never commit `config/secrets.yaml`
> (only `config/secrets.yaml.example` is tracked). Every field in the `notify:`
> block of `config/configuration.yaml` (`sender`, `username`, `recipient`) must
> stay behind `!secret`. Before committing, double-check no GPS coordinates, no
> private/local IP address, no MAC address and no personal email address ever
> end up in a tracked YAML file — `latitude`/`longitude` in particular can
> reveal a physical address to within a few meters. If you are the maintainer
> of this repository, enable secret scanning and push protection in the GitHub
> repository settings.

## Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Integrations to add through the UI](#integrations-to-add-through-the-ui)
- [Voice pipeline configuration](#voice-pipeline-configuration)
- [Available voice commands](#available-voice-commands)
- [Restoring this setup](#restoring-this-setup)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)

## Overview

- Wake word: "Hey Jarvis" (openWakeWord), handled on the Raspberry Pi.
- Speech-to-text: `wyoming-faster-whisper` (`large-v3-turbo`, CUDA, float16),
  running natively on a Windows PC with an NVIDIA GPU.
- Text-to-speech: Piper, French voice `fr_FR-siwis-medium`, on the Raspberry Pi.
- Conversation agent: Ollama (`qwen3.5:9b`), on the same Windows PC, used for
  free-form conversation. Home automation commands are handled locally by
  Home Assistant's built-in intents and by the custom `intent_script`/
  `custom_sentences` in this repository, not by the LLM.
- Audio input/output: a Generalplus USB microphone and a UACDemoV10 USB DAC/
  speaker, both attached to the Raspberry Pi.

## Architecture

```
                          Raspberry Pi
   ┌───────────────────────────────────────────────────────────┐
   │  homeassistant (Docker, host network)         :8123        │
   │  assist-microphone (Wyoming satellite)        :10700        │
   │    - USB mic  "Microphone" (arecord)                        │
   │    - USB DAC  "UACDemoV10" (aplay)                          │
   │  openwakeword (hey_jarvis, threshold 0.4)     :10400        │
   │  piper (TTS, fr_FR-siwis-medium)              :10200        │
   └───────────────────────────────────────────────────────────┘
                    │ Wyoming protocol over the LAN
                    ▼
                          Windows PC (RTX 4060, 8 GB)
   ┌───────────────────────────────────────────────────────────┐
   │  wyoming-faster-whisper (native, whisper.bat)  :10300        │
   │    large-v3-turbo, CUDA, float16, beam-size 5                │
   │  ollama (Docker)                              :11434        │
   │    qwen3.5:9b                                                │
   └───────────────────────────────────────────────────────────┘
```

Moving STT from the Pi's CPU to the PC's GPU cut speech-to-text latency from
roughly 8-9 seconds to about 1 second.

### Ports

| Service | Port | Protocol | Host |
|---|---|---|---|
| Home Assistant | 8123 | HTTP | Raspberry Pi |
| Piper (TTS) | 10200 | Wyoming | Raspberry Pi |
| assist-microphone (satellite) | 10700 | Wyoming | Raspberry Pi |
| openWakeWord | 10400 | Wyoming | Raspberry Pi |
| faster-whisper (STT) | 10300 | Wyoming | Windows PC |
| Ollama | 11434 | HTTP | Windows PC |

### Files that are not part of the active deployment

- `docker-compose-whisper.yml` and `DockerFile-whisper` build a CPU-based
  `wyoming-whisper` container (model `small`) meant to run on the Raspberry
  Pi on port 10300. This was superseded by the PC/GPU `wyoming-faster-whisper`
  setup (`whisper.bat`) described above, which is the STT path actually in
  use. Do not deploy this compose file alongside `whisper.bat` on the same
  network — both claim port 10300 as the Wyoming STT endpoint for Home
  Assistant.
- `DockerFile-openwakeword` is not referenced by `docker-compose-openwakeword.yml`,
  which pulls the `dustynv/wyoming-openwakeword:latest-r36.2.0` image directly
  instead of building it. TODO: confirm whether this Dockerfile is still
  needed, or remove it.

## Prerequisites

Raspberry Pi:
- Docker and Docker Compose.
- `alsa-utils` on the host (`arecord -l` / `aplay -l`) to identify your audio
  device names.
- A USB microphone and a USB DAC/speaker.

Windows PC:
- An NVIDIA GPU with a working CUDA setup (this project targets an RTX 4060
  with 8 GB of VRAM).
- Miniconda (or another Python environment manager).
- Docker Desktop, with GPU support enabled (WSL2 backend + NVIDIA container
  toolkit), for Ollama.

> TODO: `docker-compose-ollama.yml` does not declare an explicit GPU
> reservation (no `deploy.resources.reservations.devices` or `gpus:` entry).
> Confirm and document exactly how GPU access is granted to the `ollama`
> container on your Docker Desktop setup, or add the missing GPU declaration
> to the compose file.

> TODO: the `torchenv` conda environment used by `whisper.bat` is not captured
> anywhere in this repository (no `environment.yml` / `requirements.txt`).
> Document the exact packages (`wyoming-faster-whisper`, a CUDA-enabled
> `torch`, etc.) needed to recreate it.

## Installation

All the Docker Compose files on the Raspberry Pi use an absolute build
context of `/home/homeassistant`. Clone this repository to that exact path on
the Pi, or edit the `context:` path in every `docker-compose-*.yml` file
before building.

### 1. Raspberry Pi

```bash
git clone <REPLACE_WITH_REPO_URL> /home/homeassistant
cd /home/homeassistant

# Real secrets, never commit this file
cp config/secrets.yaml.example config/secrets.yaml
# edit config/secrets.yaml and fill in real values

# Identify your audio hardware
arecord -l
aplay -l
```

Update the `SATELLITE_MIC_DEVICE` and `SATELLITE_AUDIO_DEVICE` environment
variables in `docker-compose-homeassistant.yml` (`assist-microphone` service)
to match the ALSA **card names** returned above (e.g. `plughw:CARD=Microphone,DEV=0`),
not card numbers — card numbers are reassigned on every reboot depending on
USB enumeration order, while card names stay stable.

Bring up the services:

```bash
docker compose -f docker-compose-homeassistant.yml up -d --build
docker compose -f docker-compose-openwakeword.yml up -d
docker compose -f docker-compose-piper.yml up -d --build
```

`docker-compose-homeassistant.yml` sets `TZ=Atlantic/Reykjavik` for the
`homeassistant` container. TODO: replace this with your own timezone before
deploying.

The `assist-microphone` service overrides the satellite's startup script by
bind-mounting `assist-microphone/run` into the container
(`/etc/s6-overlay/s6-rc.d/assist_microphone/run`). This is what lets
`SATELLITE_MIC_DEVICE` and `SATELLITE_AUDIO_DEVICE` point to two distinct ALSA
devices (`arecord -D ...` for input, `aplay -D ...` for output) instead of the
single shared device the base image assumes. Two things break this file
silently:

- **Line endings.** `run` is a shell script; if it is checked out with CRLF
  line endings, the container fails with a misleading
  `no such file or directory` error instead of a syntax error. The
  `.gitattributes` file in this repository forces LF on `run` — verify this
  held after cloning (`git show HEAD:assist-microphone/run | file -`).
- **The executable bit.** It must be preserved on the host file for the
  bind-mounted script to run inside the container.

### 2. Windows PC

```bat
:: Install Miniconda, then create and populate the "torchenv" environment
:: TODO: document the exact packages, see Prerequisites above

:: Edit whisper.bat: set WHISPER_DIR to your own path (default D:\whisper)

:: Test manually before automating it
whisper.bat
```

`whisper.bat` must start automatically whenever the PC boots, or the whole
voice pipeline is broken until someone launches it by hand. Register it in
the Windows Task Scheduler:

- Trigger: at log on (or at system startup).
- Action: start `whisper.bat`.
- Add a delay of 30 seconds before the action runs, so the network and the
  GPU driver stack are ready.

Then start Ollama and pull the model:

```bat
docker compose -f docker-compose-ollama.yml up -d
docker exec -it ollama ollama pull qwen3.5:9b
```

Make sure Windows Firewall allows inbound connections to ports 10300
(faster-whisper) and 11434 (Ollama) from the Raspberry Pi's address.

## Integrations to add through the UI

Set the Home Assistant UI language to **English** in
**Settings > System > General** *before* adding any integration below. Home
Assistant derives new `entity_id`s from the UI language at creation time; if
you add integrations while the UI is in French you will get entity IDs like
`todo.liste_de_courses` instead of `todo.shopping_list`, and you will have to
rename every entity by hand afterwards through the UI (see
[Troubleshooting](#troubleshooting) for why the YAML `name:` field cannot do
this for you).

| Integration | Purpose | Setup notes |
|---|---|---|
| Wyoming Protocol | Piper (TTS) | Host/port of the `piper` container: `<pi-ip>:10200` |
| Wyoming Protocol | openWakeWord | `<pi-ip>:10400` |
| Wyoming Protocol | assist-microphone (satellite) | `<pi-ip>:10700` |
| Wyoming Protocol | faster-whisper (STT) | `<pc-ip>:10300` |
| Ollama | Conversation agent | `http://<pc-ip>:11434`, model `qwen3.5:9b` |
| Local To-do | Shopping list | Create the list with the name **"Shopping list"** (in English) so its entity ID becomes `todo.shopping_list` |
| System Monitor | Raspberry Pi health sensors | See renaming table below |
| Met.no | Weather forecast (`weather.home`) | Only source of outside data reachable by the assistant, see [Known limitations](#known-limitations) |

### Local To-do vs Shopping List

Use the **Local To-do** integration, not the built-in `shopping_list`
component. `shopping_list` does not register an entity in the entity
registry, so it cannot be given voice aliases through the UI, which breaks
voice recognition of list-related commands. With Local To-do, the entity ID
is derived from the list name you type when creating it — name it
"Shopping list" while the UI is still in English to land on
`todo.shopping_list`.

The French voice aliases for this entity (and any other entity that needs
one) must be added manually afterwards, in the entity's settings in the UI.
They are not stored in any tracked YAML file — they live in `config/.storage/`,
which is excluded from this repository (see
[Restoring this setup](#restoring-this-setup)).

### System Monitor sensor renaming

The Raspberry Pi health sensors come from the built-in **System Monitor**
integration. After adding it, rename the following entities through
**Settings > Devices & services > Entities** (UI rename, not YAML — see
[Troubleshooting](#troubleshooting)):

| Entity ID | Used by |
|---|---|
| `sensor.pi_cpu_temp` | `RaspberryStatus`, `RaspberryHealth` intents |
| `sensor.pi_load_1m` | `RaspberryHealth` intent |
| `sensor.pi_disk_use` | `RaspberryHealth` intent |
| `sensor.pi_last_boot` | `RaspberryHealth` intent |

## Voice pipeline configuration

Create an Assist pipeline in **Settings > Voice assistants**:

- Wake word: openWakeWord, `hey_jarvis` (matches `WAKEWORD_NAME` /
  `OPENWAKEWORD_PRELOAD_MODEL: hey_jarvis` in the compose files; the wake word
  detection threshold is set with `OPENWAKEWORD_THRESHOLD: 0.4` in
  `docker-compose-openwakeword.yml`).
- Speech-to-text: the faster-whisper Wyoming integration.
- Conversation agent: the Ollama integration, model `qwen3.5:9b`.
- Text-to-speech: the Piper Wyoming integration.
- Name the pipeline **"Home Assistant"**, or update `ASSIST_PIPELINE_NAME` in
  `docker-compose-homeassistant.yml` to match whatever name you choose — the
  `assist-microphone` satellite is pointed at that exact pipeline name.
- Enable **"Prefer handling commands locally"** on the pipeline.

On the Ollama conversation agent, leave **"Control Home Assistant"**
**disabled**. Enabling it lets Ollama drive Home Assistant through function
calling, but on this hardware it saturates the CPU and pushes response time
past 30 seconds; disabling it brings a typical response back down to about 3
seconds. All actual device/automation control in this repository goes through
local intents (`custom_sentences` + `intent_script`) instead, which is why
"Prefer handling commands locally" must stay on.

If you do enable Home Assistant control on the LLM, only models that support
function calling will work at all: `llama3.2:3b` and `qwen3.5:9b` were
validated, `deepseek-r1` and `gemma2` were not. `qwen3.5:9b` is the model
actually deployed here.

Ollama has no internet access through the Home Assistant integration. Any
external data the assistant needs to speak (like tomorrow's weather) has to
come from a Home Assistant integration that exposes an entity — Met.no is
that integration in this repository, see the weather pattern below.

## Available voice commands

Custom sentences live under `config/custom_sentences/fr/` and are matched to
the `intent_script` entries in `config/configuration.yaml`. Changes to
`custom_sentences/` require a full container restart
(`docker restart homeassistant`) to be picked up; changes to `intent_script`
can be reloaded from **Developer tools > YAML > Intents** without a restart.

| Intent | Example French sentence | Behavior |
|---|---|---|
| `EnvoyerListeCourses` | "envoie-moi la liste de courses par mail" | Emails the shopping list via the `courses_mail` SMTP notifier, then clears `todo.shopping_list`. Reports whether the list was empty. |
| `RaspberryStatus` | "quelle est la température du raspberry" | Reads `sensor.pi_cpu_temp` and reports whether the Pi is overheating (>=70°C) or throttling (>=80°C). |
| `RaspberryHealth` | "comment va le raspberry" | Reads CPU temperature, 1-minute load, disk usage and uptime from the System Monitor sensors. |
| `MeteoDemain` | "quel temps fait-il demain" | Reads a pre-computed `sensor.weather_tomorrow` and reports tomorrow's condition, min/max temperature, and precipitation/wind warnings. |

See `config/custom_sentences/fr/*.yaml` for the full list of recognized
phrasings per intent.

### The `intent_script` speech-template limitation

`intent_script` speech templates only have access to the matched sentence's
slots — not action results, and not `response_variable`. Two workarounds are
used in this repository:

1. **`async_action: true` + `states()`.** `EnvoyerListeCourses` fires its
   action (`script.envoyer_liste_courses`) asynchronously and reads
   `states('todo.shopping_list')` directly in the speech template to decide
   whether the list was empty, instead of waiting on the action's result.
2. **A triggered template sensor as a side channel.** `MeteoDemain` cannot
   call `weather.get_forecasts` and use its `response_variable` inside the
   intent's own speech template, so a separate trigger-based template sensor
   in `configuration.yaml` (`sensor.weather_tomorrow`, `unique_id: meteo_demain`)
   runs on a schedule (every 30 minutes) and at Home Assistant startup, calls
   `weather.get_forecasts` against `weather.home`, and stores tomorrow's
   forecast in its state and attributes. The `MeteoDemain` intent then just
   reads that sensor — it never calls the weather action itself.

This weather sensor is also a live example of why entity IDs must be renamed
through the UI: its YAML `name:` is `"Meteo tomorrow"`, but because it has a
`unique_id` it is registered once and its `entity_id` was fixed independently
at that point — it is `sensor.weather_tomorrow`, not `sensor.meteo_tomorrow`.
Editing `name:` in the YAML only changes the display label from then on, it
does not change `entity_id`.

## Restoring this setup

Git alone does **not** restore a working instance. Home Assistant's native
backups (**Settings > System > Backups**, stored off the Pi) are the
indispensable complement to this repository — take them regularly, and treat
them as the primary restore path. What follows is what to do if you only have
this Git repository and no native backup.

`config/.storage/` is excluded from this repository (see `.gitignore`). It
holds:
- every integration you configured through the UI (Wyoming endpoints, Local
  To-do, System Monitor, Met.no, Ollama, the Assist pipeline itself);
- the entity registry, i.e. every `entity_id` in this document;
- French voice aliases on entities;
- the shopping list's actual content, in
  `config/.storage/local_todo.liste_de_courses.ics`. Its filename keeps the
  French `storage_key` (`liste_de_courses`) even after the entity was renamed
  to `todo.shopping_list` in the registry — that key is set once, in
  `core.config_entries`, at the moment the list is created, and does not
  follow later renames.

`config/secrets.yaml` is also excluded, and Home Assistant will refuse to
start at all if any `!secret` reference in the YAML cannot be resolved.

To rebuild from Git only:

1. Clone the repository to `/home/homeassistant` on the Pi.
2. Recreate `config/secrets.yaml` from `config/secrets.yaml.example` with real
   values.
3. Set the UI language to English, then follow
   [Integrations to add through the UI](#integrations-to-add-through-the-ui)
   and [Voice pipeline configuration](#voice-pipeline-configuration) from
   scratch: every Wyoming endpoint, Local To-do (named "Shopping list" again),
   System Monitor sensor renames, Met.no, Ollama, and the Assist pipeline all
   have to be re-created by hand.
4. Manually re-add every French voice alias.
5. The shopping list content itself cannot be recovered from Git — it only
   existed in `config/.storage/`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `assist-microphone` container fails with "no such file or directory" | `assist-microphone/run` was checked out with CRLF line endings, or lost its executable bit | Confirm `.gitattributes` forced LF on the file; restore the executable bit on the host |
| Wake word never triggers, or triggers on background noise | `OPENWAKEWORD_THRESHOLD` in `docker-compose-openwakeword.yml` (currently `0.4`) is too high or too low for your microphone/room | Adjust the threshold and restart the `openwakeword` container |
| Satellite can't find the microphone or speaker after a reboot | `SATELLITE_MIC_DEVICE` / `SATELLITE_AUDIO_DEVICE` set with an ALSA card **number**, which is reassigned on every reboot | Use `arecord -l` / `aplay -l` to get the card **name** and use `plughw:CARD=<name>,DEV=0` |
| Voice command about the shopping list stops being recognized after a restore | French voice aliases live in `config/.storage/`, not in Git | Re-add the alias manually on the entity |
| Renaming an entity in `configuration.yaml`/`scripts.yaml` has no effect on its `entity_id` | Any entity with a `unique_id` is registered once; the YAML `name:` only changes the display label afterwards | Rename through **Settings > Devices & services > Entities** in the UI, never in YAML |
| A new `custom_sentences` phrasing is not recognized | `custom_sentences/` is only loaded at container start | `docker restart homeassistant` |
| An `intent_script` change is not picked up | — | Reload from **Developer tools > YAML > Intents**, no restart needed |
| Ollama takes 30+ seconds to answer a voice command | "Control Home Assistant" is enabled on the conversation agent | Disable it; keep "Prefer handling commands locally" enabled on the pipeline instead |
| Ollama never calls tools / function calling fails | The selected model does not support function calling | Use `qwen3.5:9b` or `llama3.2:3b`; `deepseek-r1` and `gemma2` were tested and do not work |
| Home Assistant can't reach `faster-whisper` or Ollama | Windows Firewall blocking inbound connections, or `whisper.bat` not running | Open ports 10300/11434 to the Pi; check `whisper.log` in `WHISPER_DIR` and the Task Scheduler task status |

## Known limitations

- **No STT failover.** If `wyoming-faster-whisper` on the PC becomes
  unreachable (PC off, crashed process, network issue), the entire voice
  pipeline fails with no fallback speech-to-text engine.
- **The PC is a hard dependency.** If `whisper.bat` is not running, voice
  commands do not work at all, which is why it must be registered as an
  auto-starting scheduled task (see [Installation](#installation)).
- **Ollama has no internet access.** It only "knows" what Home Assistant
  exposes as entities; any external data (like weather) must be surfaced
  through a Home Assistant integration first.
- **"Control Home Assistant" is impractical on this hardware.** It works, but
  a 30+ second response time makes it unusable for a voice assistant; it is
  kept disabled in favor of local intents.
- `docker-compose-whisper.yml` / `DockerFile-whisper` and
  `DockerFile-openwakeword` are present in the repository but not part of the
  active deployment, see
  [Files that are not part of the active deployment](#files-that-are-not-part-of-the-active-deployment).
