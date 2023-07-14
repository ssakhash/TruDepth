# TruDepth
This iOS app uses ARKit and CoreML to process depth data obtained from the LiDAR scanner on compatible iPhones. The app captures the depth data using ARKit and displays it as an image.

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
- Selection of nine points from the depth map.
- Depth value calculation for the selected points.
- Display of the selected points and their depth values on the image.
- Prerequisites
- Xcode 12 or later
- iOS 14 or later
- A LiDAR-equipped device (e.g., iPhone 12 Pro, iPhone 13 Pro)

## Usage
To use the app, simply open it and grant camera access. The app will start running an ARSession and begin collecting depth data. The depth map will be displayed as an image on the screen. Nine points will be selected from the depth map and their depth values will be printed on top of the points in the image.

## Overview
The code is structured into one main view controller (ViewController). The ViewController manages an ARSession and handles ARSessionDelegate callbacks to update the depth image and calculate depth values.

## Main functions of the ViewController include:
- viewDidLoad(): Here we configure and run the ARSession.
- session(_:didUpdate:): This function is called whenever a new ARFrame is captured. It processes the frame's depth data and updates the depth image.
- depthDataToUIImage(from:): Converts the depth data to an UIImage.
- cropToCenter(image:size:): Crops the depth image to the center.
- depthValuesForNinePoints(from:): Gets the depth values for nine selected points from the depth map.
- drawPointsAndDistances(on:depthValues:): Draws the selected points and their depth values on the depth image.

## License
This project is open source, under the MIT license.

## Contributions
Contributions are welcome. Please submit a PR or create an issue for discussion.
