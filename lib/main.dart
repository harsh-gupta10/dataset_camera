import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Get available cameras
  final cameras = await availableCameras();
  final firstCamera = cameras.first;

  runApp(
    MaterialApp(
      theme: ThemeData.dark(),
      home: CameraApp(camera: firstCamera),
    ),
  );
}

class CameraApp extends StatefulWidget {
  final CameraDescription camera;

  const CameraApp({Key? key, required this.camera}) : super(key: key);

  @override
  _CameraAppState createState() => _CameraAppState();
}

class _CameraAppState extends State<CameraApp> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  double _angle = 0.0;
  Position? _currentPosition;
  bool _hasPermissions = false;
  bool _processing = false;
  bool _compassAvailable = false;

  @override
  void initState() {
    super.initState();

    // Initialize camera controller
    _controller = CameraController(
      widget.camera,
      ResolutionPreset.high,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    // Initialize the controller future
    _initializeControllerFuture = _controller.initialize();

    // Request permissions and start sensors
    _requestPermissions();
    _initCompass();
  }

  void _initCompass() async {
    // Check if compass is available
    _compassAvailable = await FlutterCompass.events != null;

    if (_compassAvailable) {
      FlutterCompass.events!.listen((CompassEvent event) {
        if (event.heading != null) {
          setState(() {
            // Get angle from north (0-360 degrees)
            _angle = (event.heading! + 360) % 360;
          });
        }
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Compass sensor not available on this device')),
      );
    }
  }

  Future<void> _requestPermissions() async {
    final cameraStatus = await Permission.camera.request();
    final locationStatus = await Permission.location.request();

    // For Android 13+, we need to request these specific permissions
    final photosStatus = await Permission.photos.request();
    final storageStatus = await Permission.storage.request();
    final mediaLibraryStatus = await Permission.mediaLibrary.request();

    if (cameraStatus.isGranted &&
        locationStatus.isGranted &&
        (photosStatus.isGranted ||
            storageStatus.isGranted ||
            mediaLibraryStatus.isGranted)) {
      setState(() {
        _hasPermissions = true;
      });
      _getCurrentLocation();
    } else {
      setState(() {
        _hasPermissions = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Permissions not granted')),
      );
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high);
      setState(() {
        _currentPosition = position;
      });
    } catch (e) {
      print("Error getting location: $e");
    }
  }

  Future<void> _takePicture() async {
    if (_processing) return;

    if (!_hasPermissions || _currentPosition == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Missing permissions or location')),
      );
      return;
    }

    setState(() {
      _processing = true;
    });

    try {
      // Ensure camera is initialized
      await _initializeControllerFuture;

      // Capture image
      final image = await _controller.takePicture();

      // Get current time
      DateTime now = DateTime.now();
      String formattedTime = DateFormat('HH_mm').format(now);

      // Format angle to integer
      int angleInt = _angle.round();

      // Create filename
      String fileName =
          'Time_${formattedTime}_Location_${_currentPosition!.latitude.toStringAsFixed(6)}_${_currentPosition!.longitude.toStringAsFixed(6)}_Angle_$angleInt';

      // Process and save the image
      await _processAndSaveImage(image.path, fileName);

      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Photo saved: $fileName')),
      );
    } catch (e) {
      print("Error taking picture: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      setState(() {
        _processing = false;
      });
    }
  }

  Future<void> _processAndSaveImage(String imagePath, String fileName) async {
    // Read image from file
    final bytes = await File(imagePath).readAsBytes();
    final originalImage = img.decodeImage(bytes);

    if (originalImage == null) {
      throw Exception('Failed to decode image');
    }

    // Determine the crop dimensions for a square (1:1) aspect ratio
    final int cropSize = min(originalImage.width, originalImage.height);
    final int offsetX = (originalImage.width - cropSize) ~/ 2;
    final int offsetY = (originalImage.height - cropSize) ~/ 2;

    // Crop image to square (center portion)
    final croppedImage = img.copyCrop(
      originalImage,
      x: offsetX,
      y: offsetY,
      width: cropSize,
      height: cropSize,
    );

    // Get directory for saving
    Directory? directory;

    if (Platform.isAndroid) {
      // For Android, use the Pictures directory
      directory = Directory('/storage/emulated/0/Pictures/AnglePhotos');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
    } else {
      // For iOS or other platforms, use app documents directory
      final appDir = await getApplicationDocumentsDirectory();
      directory = Directory('${appDir.path}/AnglePhotos');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
    }

    // Create output file path
    final outputPath = '${directory.path}/$fileName.jpg';

    // Save the cropped image
    File(outputPath)
        .writeAsBytesSync(img.encodeJpg(croppedImage, quality: 100));

    // For Android, notify the media scanner about the new image
    if (Platform.isAndroid) {
      // Make the image visible in the gallery by scanning the file
      try {
        await _scanFile(outputPath);
      } catch (e) {
        print("Error scanning file: $e");
      }
    }
  }

  Future<void> _scanFile(String path) async {
    // For Android, we need to scan the file to make it visible in the gallery
    try {
      // Simple method to make the file visible to other apps
      final file = File(path);
      final lastModified = await file.lastModified();
      await file.setLastModified(lastModified.add(const Duration(seconds: 1)));
    } catch (e) {
      print("Failed to update file: $e");
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Angle Photo Capture')),
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Column(
              children: [
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 1, // Forces preview to be square
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.center,
                        child: FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: _controller.value.previewSize!.height,
                            height: _controller.value.previewSize!.width,
                            child: Stack(
                              children: [
                                CameraPreview(_controller),
                                Positioned(
                                  top: 20,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.6),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        'Direction: ${_angle.toStringAsFixed(1)}°',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(16.0),
                  color: Colors.black54,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Angle: ${_angle.toStringAsFixed(1)}°',
                          style: TextStyle(color: Colors.white)),
                      Text('Direction: ${_getDirectionFromAngle(_angle)}',
                          style: TextStyle(color: Colors.white)),
                      Text(
                          'Time: ${DateFormat('HH:mm').format(DateTime.now())}',
                          style: TextStyle(color: Colors.white)),
                      Text(
                        _currentPosition != null
                            ? 'Location: ${_currentPosition!.latitude.toStringAsFixed(6)}, ${_currentPosition!.longitude.toStringAsFixed(6)}'
                            : 'Location: Getting position...',
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            );
          } else {
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _processing ? null : _takePicture,
        backgroundColor: _processing ? Colors.grey : null,
        child: _processing
            ? const CircularProgressIndicator(color: Colors.white)
            : const Icon(Icons.camera_alt),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  String _getDirectionFromAngle(double angle) {
    const directions = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW', 'N'];
    return directions[(angle / 45).round() % 8];
  }
}
