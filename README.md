# TruDepth
This iOS app uses ARKit and CoreML to process depth data obtained from the LiDAR scanner on compatible iPhones. The app captures the depth data using ARKit and displays it as an image. It now supports visualization in a 7x7 grid format, displaying color-coded distance markers for efficient scanning.

## Table of Contents

- [Features](#features)
- [Usage](#usage)
- [Overview](#overview)
- [Functions](#functions)
- [License](#license)
- [Contributions](#contributions)
  
## Features
- Depth map capturing using ARKit.
- Depth map visualisation as an image.
- Selection of forty-nine points from the depth map in a 7x7 grid.
- Depth value calculation for the selected points.
- Display of the selected points and their depth values on the image.
- Distance indicators: points within a 5-meter range are colored green, and points beyond that are colored red.
- Prerequisites
  - Xcode 12 or later
  - iOS 14 or later
  - A LiDAR-equipped device (e.g., iPhone 12 Pro, iPhone 13 Pro, iPhone 14 Pro)

## Usage
To use the app, simply open it and grant camera access. The app will start running an ARSession and begin collecting depth data. The depth map will be displayed as an image on the screen. Forty-nine points, arranged in a 7x7 grid, will be selected from the depth map, and their depth values will be displayed on top of the points in the image. Each point's color indicates the distance from the device: green points are within a 5-meter range, while red points are beyond 5 meters.

## Overview
The code is structured into one main view controller (ViewController). The ViewController manages an ARSession and handles ARSessionDelegate callbacks to update the depth image and calculate depth values.

## Main functions of the ViewController include:
- viewDidLoad(): Here we configure and run the ARSession.
- session(_:didUpdate:): This function is called whenever a new ARFrame is captured. It processes the frame's depth data and updates the depth image.
- cropToSquare(image:): Crops the depth image to a square.
- generateGridPoints(for:): Generates a 7x7 grid of points within the given rectangle.
- depthValues(for:in:): Gets the depth values for the selected points from the pixel buffer.
- drawPoints(on:points:values:): Draws the selected points and their depth values on the depth image, with color coding to indicate distance.

## License
This project is open source, under the MIT license.

## Contributions
Contributions are welcome. Please submit a PR or create an issue for discussion.
