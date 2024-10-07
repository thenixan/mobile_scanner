import Flutter
import MLKitVision
import MLKitBarcodeScanning
import AVFoundation
import UIKit

public class MobileScannerPlugin: NSObject, FlutterPlugin {
    
    /// The mobile scanner object that handles all logic
    private let mobileScanner: MobileScanner
    
    /// The handler sends all information via an event channel back to Flutter
    private let barcodeHandler: BarcodeHandler
    
    /// Whether to return the input image with the barcode event.
    /// This is static to avoid accessing `self` in the callback in the constructor.
    private static var returnImage: Bool = false

    /// The points for the scan window.
    static var scanWindow: [CGFloat]?
    
    private static func isBarcodeInScanWindow(barcode: Barcode, imageSize: CGSize) -> Bool {
        let scanwindow = MobileScannerPlugin.scanWindow!
        let barcodeminX = barcode.cornerPoints![0].cgPointValue.x
        let barcodeminY = barcode.cornerPoints![1].cgPointValue.y
        
        let barcodewidth = barcode.cornerPoints![2].cgPointValue.x - barcodeminX
        let barcodeheight = barcode.cornerPoints![3].cgPointValue.y - barcodeminY
        let barcodeBox = CGRect(x: barcodeminX, y: barcodeminY, width: barcodewidth, height: barcodeheight)

        let minX = scanwindow[0] * imageSize.width
        let minY = scanwindow[1] * imageSize.height

        let width = (scanwindow[2] * imageSize.width)  - minX
        let height = (scanwindow[3] * imageSize.height) - minY

        let scaledWindow =  CGRect(x: minX, y: minY, width: width, height: height)
        
        return scaledWindow.contains(barcodeBox)
    }
    
    init(barcodeHandler: BarcodeHandler, registry: FlutterTextureRegistry) {
        self.mobileScanner = MobileScanner(registry: registry, mobileScannerCallback: { barcodes, error, image in
            if error != nil {
                barcodeHandler.publishError(
                    FlutterError(code: MobileScannerErrorCodes.BARCODE_ERROR,
                                 message: error?.localizedDescription,
                                 details: nil))
                return
            }
            
            if barcodes == nil {
                return
            }
            
            let barcodesMap: [Any?] = barcodes!.compactMap { barcode in
                if (MobileScannerPlugin.scanWindow == nil) {
                    return barcode.data
                }
                
                if (MobileScannerPlugin.isBarcodeInScanWindow(barcode: barcode, imageSize: image.size)) {
                    return barcode.data
                }

                return nil
            }
            
            if (barcodesMap.isEmpty) {
                return
            }
            
            // The image dimensions are always provided.
            // The image bytes are only non-null when `returnImage` is true.
            let imageData: [String: Any?] = [
                "bytes": MobileScannerPlugin.returnImage ? FlutterStandardTypedData(bytes: image.jpegData(compressionQuality: 0.8)!) : nil,
                "width": image.size.width,
                "height": image.size.height,
            ]
            
            barcodeHandler.publishEvent([
                "name": "barcode",
                "data": barcodesMap,
                "image": imageData,
            ])
        }, torchModeChangeCallback: { torchState in
            barcodeHandler.publishEvent(["name": "torchState", "data": torchState])
        }, zoomScaleChangeCallback: { zoomScale in
            barcodeHandler.publishEvent(["name": "zoomScaleState", "data": zoomScale])
        })
        self.barcodeHandler = barcodeHandler
        super.init()
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "dev.steenbakker.mobile_scanner/scanner/method", binaryMessenger: registrar.messenger())
        let instance = MobileScannerPlugin(barcodeHandler: BarcodeHandler(registrar: registrar), registry: registrar.textures())
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "state":
            result(mobileScanner.checkPermission())
        case "request":
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { result($0) })
        case "start":
            start(call, result)
        case "stop":
            stop(result)
        case "toggleTorch":
            toggleTorch(result)
        case "analyzeImage":
            analyzeImage(call, result)
        case "setScale":
            setScale(call, result)
        case "resetScale":
            resetScale(call, result)
        case "updateScanWindow":
            updateScanWindow(call, result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Start the mobileScanner.
    private func start(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let torch: Bool = (call.arguments as! Dictionary<String, Any?>)["torch"] as? Bool ?? false
        let facing: Int = (call.arguments as! Dictionary<String, Any?>)["facing"] as? Int ?? 1
        let formats: Array<Int> = (call.arguments as! Dictionary<String, Any?>)["formats"] as? Array ?? []
        let returnImage: Bool = (call.arguments as! Dictionary<String, Any?>)["returnImage"] as? Bool ?? false
        let speed: Int = (call.arguments as! Dictionary<String, Any?>)["speed"] as? Int ?? 0
        let timeoutMs: Int = (call.arguments as! Dictionary<String, Any?>)["timeout"] as? Int ?? 0
        self.mobileScanner.timeoutSeconds = Double(timeoutMs) / Double(1000)
        MobileScannerPlugin.returnImage = returnImage

        let barcodeOptions: BarcodeScannerOptions? = buildBarcodeScannerOptions(formats)

        let position = facing == 0 ? AVCaptureDevice.Position.front : .back
        let detectionSpeed: DetectionSpeed = DetectionSpeed(rawValue: speed)!

        do {
            try mobileScanner.start(barcodeScannerOptions: barcodeOptions, cameraPosition: position, torch: torch, detectionSpeed: detectionSpeed) { parameters in
                DispatchQueue.main.async {
                    result([
                        "textureId": parameters.textureId,
                        "size": ["width": parameters.width, "height": parameters.height],
                        "currentTorchState": parameters.currentTorchState,
                    ])
                }
            }
        } catch MobileScannerError.alreadyStarted {
            result(FlutterError(code: MobileScannerErrorCodes.ALREADY_STARTED_ERROR,
                                message: MobileScannerErrorCodes.ALREADY_STARTED_ERROR_MESSAGE,
                                details: nil))
        } catch MobileScannerError.noCamera {
            result(FlutterError(code: MobileScannerErrorCodes.NO_CAMERA_ERROR,
                                message: MobileScannerErrorCodes.NO_CAMERA_ERROR_MESSAGE,
                                details: nil))
        } catch MobileScannerError.cameraError(let error) {
            result(FlutterError(code: MobileScannerErrorCodes.CAMERA_ERROR,
                                message: error.localizedDescription,
                                details: nil))
        } catch {
            result(FlutterError(code: MobileScannerErrorCodes.GENERIC_ERROR,
                                message: MobileScannerErrorCodes.GENERIC_ERROR_MESSAGE,
                                details: nil))
        }
    }

    /// Stops the mobileScanner and closes the texture.
    private func stop(_ result: @escaping FlutterResult) {
        do {
            try mobileScanner.stop()
        } catch {}
        result(nil)
    }

    /// Toggles the torch.
    private func toggleTorch(_ result: @escaping FlutterResult) {
        mobileScanner.toggleTorch()
        result(nil)
    }
    
    /// Sets the zoomScale.
    private func setScale(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let scale = call.arguments as? CGFloat
        if (scale == nil) {
            result(FlutterError(code: MobileScannerErrorCodes.GENERIC_ERROR,
                                message: MobileScannerErrorCodes.INVALID_ZOOM_SCALE_ERROR_MESSAGE,
                                details: "The invalid zoom scale was nil."))
            return
        }
        do {
            try mobileScanner.setScale(scale!)
            result(nil)
        } catch MobileScannerError.zoomWhenStopped {
            result(FlutterError(code: MobileScannerErrorCodes.SET_SCALE_WHEN_STOPPED_ERROR,
                                message: MobileScannerErrorCodes.SET_SCALE_WHEN_STOPPED_ERROR_MESSAGE,
                                details: nil))
        } catch MobileScannerError.zoomError(let error) {
            result(FlutterError(code: MobileScannerErrorCodes.GENERIC_ERROR,
                                message: error.localizedDescription,
                                details: nil))
        } catch {
            result(FlutterError(code: MobileScannerErrorCodes.GENERIC_ERROR,
                                message: MobileScannerErrorCodes.GENERIC_ERROR_MESSAGE,
                                details: nil))
        }
    }

    /// Reset the zoomScale.
    private func resetScale(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        do {
            try mobileScanner.resetScale()
            result(nil)
        } catch MobileScannerError.zoomWhenStopped {
            result(FlutterError(code: MobileScannerErrorCodes.SET_SCALE_WHEN_STOPPED_ERROR,
                                message: MobileScannerErrorCodes.SET_SCALE_WHEN_STOPPED_ERROR_MESSAGE,
                                details: nil))
        } catch MobileScannerError.zoomError(let error) {
            result(FlutterError(code: MobileScannerErrorCodes.GENERIC_ERROR,
                                message: error.localizedDescription,
                                details: nil))
        } catch {
            result(FlutterError(code: MobileScannerErrorCodes.GENERIC_ERROR,
                                message: MobileScannerErrorCodes.GENERIC_ERROR_MESSAGE,
                                details: nil))
        }
    }

    /// Updates the scan window rectangle.
    func updateScanWindow(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let scanWindowData: Array? = (call.arguments as? [String: Any])?["rect"] as? [CGFloat]
        MobileScannerPlugin.scanWindow = scanWindowData

        result(nil)
    }
    
    static func arrayToRect(scanWindowData: [CGFloat]?) -> CGRect? {
        if (scanWindowData == nil) {
            return nil
        }

        let minX = scanWindowData![0]
        let minY = scanWindowData![1]

        let width = scanWindowData![2]  - minX
        let height = scanWindowData![3] - minY

        return CGRect(x: minX, y: minY, width: width, height: height)
    }
    
    /// Analyzes a single image.
    private func analyzeImage(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let formats: Array<Int> = (call.arguments as! Dictionary<String, Any?>)["formats"] as? Array ?? []
        let scannerOptions: BarcodeScannerOptions? = buildBarcodeScannerOptions(formats)
        let uiImage = UIImage(contentsOfFile: (call.arguments as! Dictionary<String, Any?>)["filePath"] as? String ?? "")
        
        if (uiImage == nil) {
            result(nil)
            return
        }

        mobileScanner.analyzeImage(image: uiImage!, position: AVCaptureDevice.Position.back,
                                   barcodeScannerOptions: scannerOptions, callback: { barcodes, error in
            if error != nil {
                DispatchQueue.main.async {
                    result(FlutterError(code: MobileScannerErrorCodes.BARCODE_ERROR,
                                        message: error?.localizedDescription,
                                        details: nil))
                }
                
                return
            }
            
            if (barcodes == nil || barcodes!.isEmpty) {
                DispatchQueue.main.async {
                    result(nil)
                }
                
                return
            }
            
            let barcodesMap: [Any?] = barcodes!.compactMap { barcode in barcode.data }
            
            DispatchQueue.main.async {
                result(["name": "barcode", "data": barcodesMap])
            }
        })
    }
    
    private func buildBarcodeScannerOptions(_ formats: [Int]) -> BarcodeScannerOptions? {
        guard !formats.isEmpty else {
            return nil
        }

        var barcodeFormats: BarcodeFormat = []

        for format in formats {
            barcodeFormats.insert(BarcodeFormat(rawValue: format))
        }

        return BarcodeScannerOptions(formats: barcodeFormats)
    }
}
