# Design Document

## Features

- Use AVCapture to use both front and back camera
- "Record" button which starts the recording / automatic dashcam
- Settings menu to choose whether to use front camera, back camera, or both
- Collision detection using internal gyro or acceleration spike
- On collision, automatically save video to files and attempt upload to cloud
    - For now just worry about saving the video locally
- During recording, cache 1 minute (or a specified amount of time) of video and finalize the saved file when hitting a "Save" button. 