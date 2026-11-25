# Sing Match (iPhone)

Import a song → the vocals are split from the music on the phone → the vocal melody is written out as notes → sing along and see your pitch against the notes, with a live score.

## Features
- **Import** any audio file from Files (MP3, M4A, WAV, AIFF, FLAC…), **or a video** from Files or your Photos library (MP4, MOV, M4V…). The soundtrack is taken from the video automatically. Up to 10 minutes.
- **Vocal separation on the phone** using the open-source UVR MDX-Net "Voc_FT" model, run with Apple's Core ML. No server and no upload.
- **Notation**: the melody is detected from the isolated vocal (YIN pitch tracking) and shown as a scrolling note lane with note names (C4, F♯3…).
- **Sing and match**: the mic pitch is drawn live as a trail. Green means you're in tune, pink means you're off. It shows cents sharp/flat, colours each note by how well you hit it, and gives a % score. Your best score is saved for each song.
- **Your voice in blue**: your pitch is a blue line that turns green on the note; a faint grey line follows everything the original singer does.
- **Record and play back**: the app records you while you sing. Play back your own singing, or a pitch-corrected version moved onto the right notes, with the chart showing what you sang against where it should be.
- **Octave options**: buttons for Deeper/Higher (±3 octaves), **Auto** (picks the octave you're actually singing in), **Any octave counts**, and you can choose to shift the guide vocal too.
- **Mix**: separate volume sliders for the guide vocal and the music.
- **Difficulty**: Easy ±100¢, Normal ±50¢, Hard ±25¢.
- **Echo cancelling** for when you're using the phone speaker. Headphones still give the best results.

## Build with Codemagic (from Windows)
1. In the Apple Developer portal, register the bundle ID `com.stevenwilliams.singmatch`. Then create the app in App Store Connect.
2. Push this folder to a new GitHub repo and add it in Codemagic.
3. `codemagic.yaml` already uses your **Berfau ASC** integration. It will:
   - download the vocal model, convert it to Core ML, check it still matches the original, and bundle it into the app
   - generate the Xcode project with XcodeGen (no Mac needed)
   - sign the app, build the IPA and upload it to TestFlight

## Project layout
```
SingMatch/App/       SwiftUI app entry, song library + storage
SingMatch/Audio/     decoding, STFT + ONNX vocal separation, YIN pitch, melody extraction, playback/mic session
SingMatch/Views/     library, processing sheet, sing screen, scrolling piano roll
project.yml          XcodeGen project (no third-party packages)
scripts/             ONNX → Core ML model conversion, run during the Codemagic build
codemagic.yaml       CI build → TestFlight
```

## Notes
- The separation pipeline (STFT settings, chunking, model input/output layout) and the melody extraction were checked against a real song in Python before being written in Swift. The vocal stem was silent in the instrumental sections, and the extracted melody came out as clean notes.
- Processing a 3–4 minute song takes roughly 1–3 minutes on a recent iPhone. The screen is kept awake while it runs.
- Before an App Store release, check the licence for the UVR model you're bundling. The UVR project is MIT-licensed.
