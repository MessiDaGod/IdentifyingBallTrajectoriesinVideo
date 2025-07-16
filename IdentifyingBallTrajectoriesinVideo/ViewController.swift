//
//  ViewController.swift
//  IdentifyingBallTrajectoriesinVideo
//
//  Created by AM1820 on 2020/12/17.
//

import UIKit
import AVFoundation
import Vision

class ViewController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    @IBOutlet var previewView: PreviewView!
    // Properties for UI
    private let captureSession = AVCaptureSession()
    private let captureSessionQueue = DispatchQueue(label: "IdentifyingBallTrajectoriesinVideo.CaptureSessionQueue", qos: .userInteractive)
    
    // Properties for capturing a video
    private var videoDataOutput = AVCaptureVideoDataOutput()
    private let videoDataOutputQueue = DispatchQueue(label: "IdentifyingBallTrajectoriesinVideo.VideoDataOutputQueue", qos: .userInteractive)
    
    // Properties for detecting trajectories
    private var request: VNDetectTrajectoriesRequest!
    private let trajectoryQueue = DispatchQueue(label: "IdentifyingBallTrajectoriesinVideo.Trajectory", qos: .userInteractive)
    
    // Properties for drawing trajectories
    private var trajectoryLayer = [CAShapeLayer]()
    private var trajectoryDictionary: [UUID: TrajectoryProperty] = [:]
    var roiRect: CGRect?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let uploadButton = UIButton(type: .system)
        uploadButton.setTitle("Upload Video", for: .normal)
        uploadButton.frame = CGRect(x: 20, y: 40, width: 150, height: 40)
        uploadButton.addTarget(self, action: #selector(pickVideoFromLibrary), for: .touchUpInside)
        view.addSubview(uploadButton)
        
        
        request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: 10, completionHandler: completionHandler)
        
        previewView.videoPreviewLayer.session = captureSession
        previewView.videoPreviewLayer.videoGravity = .resizeAspect
        previewView.frame = view.bounds
        
        panGestureRectLayer.strokeColor = UIColor.blue.cgColor
        panGestureRectLayer.lineWidth = 3.0
        panGestureRectLayer.fillColor = UIColor.clear.cgColor
        panGestureRectLayer.lineCap = .round
        panGestureRectLayer.opacity = 0.2
        
        captureSessionQueue.async {
            self.setupCamera()
        }
    }
    
    @objc func pickVideoFromLibrary() {
        // Stop camera safely if it's running
        captureSessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }

        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.mediaTypes = ["public.movie"]
        picker.delegate = self
        DispatchQueue.main.async {
            self.present(picker, animated: true)
        }
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        dismiss(animated: true)

        guard let mediaURL = info[.mediaURL] as? URL else {
            print("❌ Could not get mediaURL")
            return
        }

        print("✅ Selected video URL: \(mediaURL)")

        // If you want to process it with Vision:
        processVideoAtURL(mediaURL)
    }

    func processVideoAtURL(_ url: URL) {
        
        let asset = AVAsset(url: url)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            print("❌ Could not create AVAssetReader:", error)
            return
        }
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = self.previewView.bounds
        playerLayer.videoGravity = .resizeAspect
        player.play()
        
        DispatchQueue.main.async {
            self.previewView.layer.sublayers?.forEach { $0.removeFromSuperlayer() } // Clear old layers
            self.previewView.layer.addSublayer(playerLayer)
        }
        
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            print("❌ No video track found")
            return
        }
        
        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)
        
        if !reader.startReading() {
            print("❌ Failed to start reading")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            while reader.status == .reading {
                guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { break }
                
                let requestHandler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .right, options: [:])
                
                self.trajectoryQueue.async {
                    if let rect = self.roiRect {
                        self.request.regionOfInterest = rect
                    } else {
                        self.request.regionOfInterest = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
                    }
                    
                    do {
                        try requestHandler.perform([self.request])
                        DispatchQueue.main.async {
                            self.drawTrajectories(self.trajectoryDictionary)
                        }
                    } catch {
                        print("❌ Vision error:", error)
                    }
                }
                
                usleep(30_000) // Slow down processing to match video (~33 fps)
            }
        }
    }

    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession.stopRunning()
        request = nil
    }
    
    var panGestureRect: CGRect?
    var panGestureBeganPoint: CGPoint?
    var panGestureEndedPoint: CGPoint?
    var panGestureRectLayer: CAShapeLayer = CAShapeLayer()
    
    @IBAction func tapGesture(_ sender: UITapGestureRecognizer) {
        switch sender.state {
        case .ended:
            request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: 10, completionHandler: completionHandler)
            
            panGestureRectLayer.removeFromSuperlayer()
            roiRect = nil
            panGestureBeganPoint = nil
            panGestureEndedPoint = nil
            panGestureRect = nil
        default:
            break
        }
    }
    
    @IBAction func panGesture(_ sender: UIPanGestureRecognizer) {
        switch sender.state {
        case .began:
            print("began")
            let location = sender.location(in: previewView)
            panGestureBeganPoint = CGPoint(x: location.x, y: location.y)
            panGestureRectLayer.removeFromSuperlayer()
        case .ended:
            print("ended")
            request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero, trajectoryLength: 10, completionHandler: completionHandler)
            
            let location = sender.location(in: previewView)
            panGestureEndedPoint = CGPoint(x: location.x, y: location.y)
            
            if let p0 = panGestureEndedPoint, let p1 = panGestureBeganPoint {
                panGestureRect = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x-p0.x), height: abs(p1.y-p0.y))
                let panGestureRectPath: UIBezierPath = UIBezierPath(rect: panGestureRect!)
                panGestureRectLayer.path = panGestureRectPath.cgPath
                previewView.videoPreviewLayer.addSublayer(panGestureRectLayer)
            }
            
            if let rect = panGestureRect {
                roiRect = convertRectToVisionCoordinates(rect: rect)
            }
        case .changed:
            panGestureRectLayer.removeFromSuperlayer()
            
            let location = sender.location(in: previewView)
            panGestureEndedPoint = CGPoint(x: location.x, y: location.y)
            
            if let p0 = panGestureEndedPoint, let p1 = panGestureBeganPoint {
                panGestureRect = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x-p0.x), height: abs(p1.y-p0.y))
                let panGestureRectPath: UIBezierPath = UIBezierPath(rect: panGestureRect!)
                panGestureRectLayer.path = panGestureRectPath.cgPath
                previewView.videoPreviewLayer.addSublayer(panGestureRectLayer)
            }
            
        default:
            break
        }
    }
    

    // MARK: - Camera setup
    func setupCamera() {
        print("setupCamera")
        captureSession.beginConfiguration()

        // Get the camera device
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("⚠️ No camera device found")
            return
        }

        // Set session preset based on device capabilities
        if videoDevice.supportsSessionPreset(.hd1920x1080) {
            captureSession.sessionPreset = .hd1920x1080
        } else {
            captureSession.sessionPreset = .high
        }

        // Configure input
        do {
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            if captureSession.canAddInput(videoDeviceInput) {
                captureSession.addInput(videoDeviceInput)
            } else {
                print("⚠️ Cannot add camera input")
                return
            }
        } catch {
            print("⚠️ Error creating AVCaptureDeviceInput:", error)
            return
        }

        // Configure output
        if captureSession.canAddOutput(videoDataOutput) {
            captureSession.addOutput(videoDataOutput)
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
            videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
        } else {
            print("⚠️ Could not add video data output")
            return
        }

        if let captureConnection = videoDataOutput.connection(with: .video) {
            captureConnection.preferredVideoStabilizationMode = .standard
            captureConnection.isEnabled = true
        }

        captureSession.commitConfiguration()
        captureSession.startRunning()
        print("✅ Camera setup complete")
    }


    // MARK: - Vision handler
    func completionHandler(request: VNRequest, error: Error?) {
        for uuid in trajectoryDictionary.keys {
            // If the trajectory with the same key(UUID) is not detected after 5 frames, delete it.
            if trajectoryDictionary[uuid]!.count > 5 {
                trajectoryDictionary[uuid] = nil
            }else {
                trajectoryDictionary[uuid]!.count += 1
            }
        }
        
        if let e = error {
            print(e)
            return
        }
        
        guard let observations = request.results as? [VNTrajectoryObservation] else { return }


        for observation in observations {
            if observation.confidence < 0.9 { continue }
            print(observation.detectedPoints)
            print(observation.projectedPoints)
            print(observation)
            // Do not selet if confidence is less than 0.9
            //if observation.confidence < 0.9 { continue }
            let uuid: UUID = observation.uuid
            // Convert the coordinates of the bottom-left to ones of the upper-left
            let detectedPoints: [CGPoint] = observation.detectedPoints.compactMap {point in
                return CGPoint(x: point.x, y: 1 - point.y)
            }
            let projectedPoints: [CGPoint] = observation.projectedPoints.compactMap { point in
                return CGPoint(x: point.x, y: 1 - point.y)
            }
            
            if trajectoryDictionary.keys.contains(uuid){
                trajectoryDictionary[uuid]!.detectedPoints.append(detectedPoints.last!)
                trajectoryDictionary[uuid]!.projectedPoints = projectedPoints
                trajectoryDictionary[uuid]!.equationCoefficients = observation.equationCoefficients
                trajectoryDictionary[uuid]!.confidence = observation.confidence
                trajectoryDictionary[uuid]!.count = 0
            }else {
                trajectoryDictionary[uuid] = TrajectoryProperty(detectedPoints: detectedPoints, projectedPoints: projectedPoints, equationCoefficients: observation.equationCoefficients, confidence: observation.confidence)
            }
        }
        
        drawTrajectories(trajectoryDictionary)
    }
    
    // MARK: - Trajectory drawing
    
    // Remove all drawn trajectories. Must be called on main queue.
    func removeTrajectoryLayers() {
        for layer in trajectoryLayer {
            layer.removeFromSuperlayer()
        }
        trajectoryLayer.removeAll()
    }
    
    // Draw a Trajectory on screen. Must be called from main queue.
    func drawTrajectories(_ dict: [UUID: TrajectoryProperty]) {
        DispatchQueue.main.async {
            self.removeTrajectoryLayers()
            if dict.isEmpty { return }

            let detectedPointPath = UIBezierPath()
            let projectedPointPath = UIBezierPath()

            for trajectoryProperty in dict.values {
                let detectedPoints = trajectoryProperty.detectedPoints
                let projectedPoints = trajectoryProperty.projectedPoints

                guard !detectedPoints.isEmpty else { continue }
                detectedPointPath.move(to: self.convertPointToUIViewCoordinates(normalizedPoint: detectedPoints[0]))
                for point in detectedPoints {
                    detectedPointPath.addLine(to: self.convertPointToUIViewCoordinates(normalizedPoint: point))
                }

                if !projectedPoints.isEmpty {
                    projectedPointPath.move(to: self.convertPointToUIViewCoordinates(normalizedPoint: projectedPoints[0]))
                    for point in projectedPoints {
                        projectedPointPath.addLine(to: self.convertPointToUIViewCoordinates(normalizedPoint: point))
                    }
                }
            }

            let detectedPointLayer = self.createCAShapeLayer(path: detectedPointPath.cgPath, strokeColor: UIColor.red.cgColor)
            self.trajectoryLayer.append(detectedPointLayer)
            self.previewView.layer.addSublayer(detectedPointLayer)

            let projectedPointLayer = self.createCAShapeLayer(path: projectedPointPath.cgPath, strokeColor: UIColor.green.cgColor)
            self.trajectoryLayer.append(projectedPointLayer)
            self.previewView.layer.addSublayer(projectedPointLayer)
        }
    }


    func createCAShapeLayer(path: CGPath, strokeColor: CGColor) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.strokeColor = strokeColor
        layer.lineWidth = 3.0
        layer.fillColor = UIColor.clear.cgColor
        layer.lineCap = .round
        layer.opacity = 0.3
        
        return layer
    }
    
    func convertPointToUIViewCoordinates(normalizedPoint: CGPoint) -> CGPoint {
        // Convert normalized coordinates to UI View's ones
        let convertedX: CGFloat
        let convertedY: CGFloat
        
        if let rect = panGestureRect {
            // If ROI is setting
            convertedX = rect.minX + normalizedPoint.x*rect.width
            convertedY = rect.minY + normalizedPoint.y*rect.height
        }else {
            let videoRect = previewView.videoPreviewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0))
            convertedX = videoRect.origin.x + normalizedPoint.x*videoRect.width
            convertedY = videoRect.origin.y + normalizedPoint.y*videoRect.height
        }
        
        return CGPoint(x: convertedX, y: convertedY)
    }
    
    func convertRectToVisionCoordinates(rect: CGRect) -> CGRect {
        let videoRect = previewView.videoPreviewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0))
        let normalizedRect = CGRect(x: (rect.minX - videoRect.origin.x)/videoRect.width, y: (rect.minY - videoRect.origin.y)/videoRect.height, width: rect.width/videoRect.width, height: rect.height/videoRect.height)
        let visionRect = CGRect(x: normalizedRect.minX, y: 1 - normalizedRect.maxY, width: abs(normalizedRect.width), height: abs(normalizedRect.height))
        return visionRect
    }
}


// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        let requestHandler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .right, options: [:])
        trajectoryQueue.async {
            
            if let rect = self.roiRect {
                self.request.regionOfInterest = rect
            }else {
                // default setting
                self.request.regionOfInterest = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
            }
            
            do {
                try requestHandler.perform([self.request])
            } catch {
                // Handle the error.
            }
        }
    }
}

struct TrajectoryProperty {
    var detectedPoints: [CGPoint]
    var projectedPoints: [CGPoint]
    var equationCoefficients: simd_float3
    var confidence: Float
    var count: Int = 0
}

// MARK: - Apply business logic
extension ViewController {
    func isROI(detectedPoints: [CGPoint], roi: CGRect) -> Bool {
        let l0 = CGPoint(x: detectedPoints[0].x, y: detectedPoints[0].y)
        let l4 = CGPoint(x: detectedPoints[4].x, y: detectedPoints[4].y)
        let p: [CGPoint] = [CGPoint(x: roi.minX, y: roi.minY), CGPoint(x: roi.maxX, y: roi.minY), CGPoint(x: roi.maxX, y: roi.maxY), CGPoint(x: roi.minX, y: roi.maxY)]
        
        for i in 0 ... 3 {
            let determinant: CGFloat = (l4.x - l0.x)*(-p[(i+1)%4].y + p[i].y) - (l4.y - l0.y)*(-p[(i+1)%4].x + p[i].x)
            if determinant == 0 {
                continue
            }
            let s: CGFloat = 1/determinant * ((-p[(i+1)%4].y + p[i].y)*(p[i].x - l0.x) + (p[(i+1)%4].x - p[i].x)*(p[i].y - l0.y))
            let t: CGFloat = 1/determinant * ((-l4.y + l0.y)*(p[i].x - l0.x) + (l4.x - l0.x)*(p[i].y - l0.y))
            if s <= 0 && 0 <= t && t <= 1 {
                return true
            }
        }
        return false
    }
}
