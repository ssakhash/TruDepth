# TruDepth

This iOS app uses ARKit to process depth data obtained from the LiDAR scanner on compatible iPhones. The app captures the camera feed and depth data using ARKit and displays it in two separate image views. It supports visualization in an 8x8 grid format, displaying color-coded distance markers with corresponding depth values for efficient scanning.

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [Overview](#overview)
- [Main Functions](#main-functions)
- [Contributions](#contributions)

## Features

- Camera feed display using ARKit.
- Depth map capturing using ARKit.
- Depth map visualisation as an image.
- Selection of sixty-four points from the depth map in an 8x8 grid.
- Depth value calculation for the selected points.
- Display of the selected points and their depth values on the image.
- Distance indicators: points within a 5-meter range are colored green, and points beyond that are colored red.

## Prerequisites

- Xcode 12 or later
- iOS 14 or later
- A LiDAR-equipped device (e.g., iPhone 12 Pro, iPhone 13 Pro, iPhone 14 Pro)

## Usage

To use the app, simply open it and grant camera access. The app will start running an ARSession and begin collecting both camera feed and depth data. The live camera feed will be displayed on one image view, and the depth map will be displayed on another. Sixty-four points, arranged in an 8x8 grid, will be selected from the depth map, and their depth values will be displayed on top of the points in the image. Each point's color indicates the distance from the device: green points are within a 5-meter range, while red points are beyond 5 meters.

## Overview

The code is structured into one main view controller (ViewController). The ViewController manages an ARSession, displays the live camera feed, and handles ARSessionDelegate callbacks to update the depth image and calculate depth values.

## Main Functions

- `viewDidLoad()`: Configures and runs the ARSession.
- `session(_:didUpdate:)`: Called whenever a new ARFrame is captured. It processes the frame's camera feed and depth data and updates the respective image views.
- `cropToSquare(image:)`: Crops the input image (either camera feed or depth image) to a square.
- `generateGridPoints(for:)`: Generates an 8x8 grid of points within the given rectangle.
- `depthValues(for:in:)`: Gets the depth values for the selected points from the pixel buffer.
- `drawPoints(on:points:values:)`: Draws the selected points and their depth values on the depth image, with color coding to indicate distance.

## Contributions

Contributions are welcome. Please submit a PR or create an issue for discussion.
