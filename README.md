# glTF Sequence Exporter Mod for BeamNG.drive

A mod to export a BeamNG.drive replay as a sequence of glTF files.

This mod takes advantage of BeamNG.drive's Replay feature and the existing experimental glTF exporter to export each frame as a .glb/.gltf file.

Use my Blender add-on [BeamNG glTF Sequence Importer](https://github.com/oli-caon/beamng-gltf-sequence-importer) to import the sequence into Blender as an animation.

## Installation

Download this repository as a zip file and place it in the mods folder in your BeamNG.drive user folder. See [BeamNG's tutorial](https://documentation.beamng.com/tutorials/mods/installing-mods/#manual-installation) for more info.

In BeamNG.drive, add the "glTF Sequence Exporter" UI app via the pause menu under the "UI Apps" tab.

## Quick Start

1. Select your replay with the Replay UI app.
2. Set the frame rate and sequence frame range.
3. Confirm the export path (existing files will be overwritten!).
4. Press the **Export Sequence** button and wait for it to finish.
5. Find your exported sequence in your BeamNG.drive user folder.
6. Optionally import the sequence into Blender using the [BeamNG glTF Sequence Importer add-on](https://github.com/oli-caon/beamng-gltf-sequence-importer).

## Usage

To get started, record a replay in BeamNG.drive and play it using the Replay UI app. See [BeamNG's documentation](https-external://documentation.beamng.com/getting_started/replay) for help on that.

With a replay selected you can choose the settings for your sequence. The timeline shows the current frame number and highlights your start and end range. Note that you can't use this to seek through the replay - use the Replay UI app controls for that.

The **Set/Clear Origin** button will use your vehicle's current position for the origin position in the glTF files. When a new replay is loaded the origin is set to the first frame. If you clear the origin, the game's world origin is used, which may mean the exported vehicle ends up very far away from the scene's origin.

The export path is relative to your `BeamNG.drive/{version}/` folder and includes a prefix for each frame's filename.
For example, with the file path set to `/vehicles/pickup/export_frame_`, frame 1 would be exported to `C:\Users\{user}\AppData\Local\BeamNG.drive\{version}\vehicles\pickup\export_frame_00001.glb`.  
This property is updated whenever you switch vehicles. Be aware that existing files with the same name will be overwritten without warning.

The default export options should be fine for most cases. I recommended you keep **External Textures**  enabled otherwise every frame will be exported with its own copy of the textures, which can quickly add up to several gigabytes for even a short sequence.

When you're happy with your settings, press the **Export Sequence** button and the app will begin playing the replay and writing out each frame. Don't touch the replay controls while it is working. The replay might play for a second before reaching your start frame. The first time you export a new vehicle, it will take longer to export the first frame because the textures will need to be converted from .dds to .png.

## Limitations

- The frame rate of a replay depends on the game's FPS when it was recorded. Try locking your FPS when recording a replay for smoother results. You can still export the replay at whatever frame rate you like but the animation smoothness will depend on the source FPS.
- Frame pacing is not 100% accurate for exported frames. There is a trade-off between accuracy and export wait times.
- Sequence file sizes can become quite large, with frame files between 3MB and 15MB. This tool is best used for creating animations featuring mesh deformation and destruction where the geometry changes a lot between frames.
- You are only able to seek through replays in 1 second increments. This is due to how the replay system works and doesn't seem to be something I can change.
- Materials properties may not always appear correct and vehicle paint colours are not currently exported. These are limitations of the existing glTF export functionality.
- This doesn't work with the Vulkan renderer.
