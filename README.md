# speech

A text-to-speech workbench for monome norns. Enter or load a phrase, render it
with eSpeak NG, flite, or Piper, audition it, and save the result as a WAV
sample.

This began as an idea for a nota bene voice. eSpeak has to synthesize new audio
when its text or settings change, so it cannot provide the deterministic
note-on timing expected from an ordinary nb voice. This script makes that
rendering step explicit and produces samples that can be used in a sampler or
sample-based nb voice afterward.

## Requirements

Install SoX and at least one speech backend. eSpeak NG and flite are available
from the norns package repository:

```sh
sudo apt update
sudo apt install espeak-ng flite sox
```

For Piper on desktop norns, install the isolated Python package and put the
model and its adjacent JSON configuration in a permanent location:

```sh
pipx install piper-tts
mkdir -p ~/.local/share/piper/voices
install -m 0644 ~/Downloads/en_GB-alan-low.onnx* \
  ~/.local/share/piper/voices/
```

This Alan voice path is the script default. Other Piper `.onnx` models can be
selected from PARAMETERS.

Current `piper-tts` Python wheels do not support the 32-bit ARMv7 norns Shield.
On a Shield running norns `260616`, install Piper's standalone ARMv7 release
instead:

```sh
mkdir -p ~/.local/share/piper/runtime
curl -fL \
  https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_armv7l.tar.gz \
  -o /tmp/piper_linux_armv7l.tar.gz
tar xzf /tmp/piper_linux_armv7l.tar.gz \
  -C ~/.local/share/piper/runtime
sudo ln -sfn ~/.local/share/piper/runtime/piper/piper \
  /usr/local/bin/piper
```

Copy the model files from the desktop with:

```sh
ssh we@norns.local 'mkdir -p ~/.local/share/piper/voices'
scp ~/Downloads/en_GB-alan-low.onnx* \
  we@norns.local:/home/we/.local/share/piper/voices/
```

## Install

From maiden:

```text
;install https://github.com/vehka/speech
```

Then refresh the script list and launch **speech**.

## Controls

- **E1** selects phrase 1-9. The selected phrase number appears in the header.
- **E2** selects a setting for the active speech backend.
- **E3** changes the selected setting.
- **K2** renders the current phrase and previews it once. Press K2 during
  playback to stop it.
- **K3** renders the current phrase to the norns audio library.
- **K1 > PARAMETERS** selects the backend, loads text, and edits phrases,
  voice, output name, and synthesis settings.

Preview and save are also available as triggers in the parameters menu.

## Parameters

- **phrase** selects the active phrase slot. Phrase 1 defaults to `I am Norns.`;
  phrases 2-9 default to empty.
- **PHRASES** opens a submenu containing all nine phrases. Select a numbered
  phrase with K3 to open the wrapped text editor.
- **load text file** opens the norns file selector and replaces the active
  phrase with the selected text file's contents.
- **eSpeak voice** lists the voices reported by `espeak-ng --voices`.
- **flite voice** lists the voices reported by `flite -lv`.
- **Piper model** selects an ONNX voice model. Its `.onnx.json` configuration
  must be in the same directory.
- **output name** is sanitized to a filename; `.wav` is optional.

The phrases and output name use the same text editor.

### Text Editor

- With a keyboard connected, the editor shows five wrapped lines. Type to
  insert at the cursor; use Left/Right, Home/End, Backspace, and Delete to edit.
  Enter saves and Escape cancels.
- Without a keyboard, the editor shows three wrapped lines above the standard
  character picker. E2 selects a character or DEL/OK, E3 changes rows, K3 acts,
  and K2 cancels.
- The visible lines follow the cursor, so the insertion point and latest words
  remain on screen. Moving an encoder switches to the character-picker view.

## Backends

- **eSpeak NG** provides speed, pitch, pitch range, amplitude, and word-gap
  controls.
- **flite** provides duration-stretch and pitch-shift controls. Stretch values
  above `1.00x` speak more slowly, while lower values speak more quickly. Pitch
  is adjustable by +/-12 semitones.
- **Piper** provides length, noise, and noise-width controls. Length values
  above `1.00x` speak more slowly. The noise controls vary voice generation;
  the initial values match the Alan model configuration.

Only the active backend's settings are shown in the parameters menu. You only
need to install the backend you intend to use, plus SoX.

The phrases, active phrase number, and settings are ordinary norns params, so
they are stored in the script's psets. Saved audio is written separately to:

```text
~/dust/audio/speech/
```

## Notes

- Parameter changes affect the next K2/K3 render, not speech already playing.
- The initial eSpeak speech rate is 120 WPM.
- Output is resampled to norns' 48 kHz audio rate before previewing or saving.
- Preview files receive a short silent tail to work around norns tape playback
  dropping its final buffered audio. This padding is not added to saved WAVs.
- Preview uses norns' shared tape player. Starting a preview replaces any
  current tape playback; it does not affect tape recording.
- Rendering is normally quick for short phrases, but matron may pause briefly
  while the selected backend creates the WAV.
- Piper on the ARMv7 Shield loads the Alan model in about 2.5 seconds and
  renders at approximately real time.
- Render errors are logged to `~/dust/data/speech/speech.log`.

## License

MIT
