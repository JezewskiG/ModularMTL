//
//  ModularRenderer.swift
//
//
//  Created by Gracjan J on 13/02/2022.
//

import Foundation
import MetalKit
import MetalPerformanceShaders
import MetalFX

public class ModularRenderer {
    
    // MARK: - Internal parameters
    var device: MTLDevice!
    
    var drawInViewPSO: MTLRenderPipelineState!
    var computeLinesPSO: MTLComputePipelineState!
    var offscreenRenderPSO: MTLRenderPipelineState!
    
    var offscreenRenderPD: MTLRenderPassDescriptor!
    
    var blurTexture: MTLTexture!
    var renderTargetTexture: MTLTexture!
    
    // MetalFX Upscaling
    var upscaledTargetTexture: MTLTexture!
    var spatialScaler: MTLFXSpatialScaler!
    
    var library: Library!
    var data: RendererObservableData
    
    var linesBuffer: ManagedBuffer<simd_float4>!
    
    var blurKernel: MPSUnaryImageKernel!
    
    
    
    // MARK: - Init methods
    public init?(with data: RendererObservableData, device: MTLDevice) throws {
        self.data = data
        self.device = device
        
        let result = Helper.merge({ self.prepareDevice()    },
                                  { self.prepareBuffers()   },
                                  { self.prepareLibrary()   },
                                  { self.preparePipelines() },
                                  { self.prepareTextures()  },
                                  { self.prepareUpscaler()  })
        
        switch result {
            case .success():
                return
            case .failure(let error):
                throw error
        }
    }
    
    
    private func prepareDevice() -> Result<Void, RendererError> {
        if device.supportsFamily(.apple7) {
            self.blurKernel = MPSImageGaussianBlur(device: device, sigma: 55)
        }
        else {
            data.status = .Limited
        }
        return .success(Void())
    }
    
    
    private func prepareUpscaler() -> Result<Void, RendererError> {
        // Check if hardware supports Metal 3 to use MetalFX.
        if device.supportsFamily(.metal3) {
            
            let desc = MTLFXSpatialScalerDescriptor()
            // Take base resolution of render as input resolution for upscaler
            desc.inputWidth = data.baseResolution.0
            desc.inputHeight = data.baseResolution.1
            
            // Take upscaled resolution (baseResolution * upscalingFactor) as output resolution of upscaler
            // By default, `upscalingFactor = 2`
            desc.outputWidth = data.upscaledResolution.0
            desc.outputHeight = data.upscaledResolution.1
            
            desc.colorTextureFormat = .bgra8Unorm_srgb
            desc.outputTextureFormat = .bgra8Unorm_srgb
            
            // Use perceptual color processing mode (SRGB texture format above)
            desc.colorProcessingMode = .perceptual
            
            // Make the upscaler
            self.spatialScaler = desc.makeSpatialScaler(device: device)
            
            guard let spatialScaler else {
                return .failure(.UnsupportedDevice(Details: "Error creating MetalFX Spatial Scaler."))
            }
            
            // Create a texture for upscaled output. Size matches Spatial Scaler output from descriptor.
            let upscaledTextureResult = TextureManager.getTexture(with: device,
                                                                 format: .bgra8Unorm_srgb,
                                                                 sizeWH: data.upscaledResolution,
                                                                 type: .renderTarget,
                                                                 label: "UpscaledRenderTargetTexture")
            
            do {
                self.upscaledTargetTexture = try upscaledTextureResult.get()
            }
            catch let error as RendererError {
                return .failure(error)
            }
            catch {
                return .failure(.TextureCreationError(Details: "Unknown error."))
            }
        }
        
        // Primitive flag indicating that Upscaling is supported.
        data.upscalingEnabled = true
        return .success(Void())
    }
    
    
    private func prepareLibrary() -> Result<Void, RendererError> {
        let functionsList = [
            "computeLinesFunction",
            "fragmentFunction", "linesVertexFunction",
            "quadFragmentFunction", "quadVertexFunction",
        ]
        
        do {
            self.library = try Library(with: device, functions: functionsList)
        }
        catch let error as RendererError {
            return .failure(error)
        }
        catch {
            return .failure(.LibraryCreationError(Details: "Unknown error."))
        }
        
        return .success(Void())
    }
    
    
    private func prepareBuffers() -> Result<Void, RendererError> {
        let minimumSize: UInt = 100
        
        do {
            self.linesBuffer = try ManagedBuffer(with: device,
                                                 count: data.pointsCount,
                                                 minimum: minimumSize,
                                                 label: "LinesBuffer")
        }
        catch let error as RendererError {
            return .failure(error)
        }
        catch {
            return .failure(.BufferCreationError(Details: "Unknown error."))
        }
    
        return .success(Void())
    }
    
    
    private func preparePipelines() -> Result<Void, RendererError> {
        do {
            let offscreenRPD = MTLRenderPipelineDescriptor()
            offscreenRPD.label = "Offscreen Render Pass"
            offscreenRPD.vertexFunction = try library.createFunction(name: "linesVertexFunction").get()
            offscreenRPD.fragmentFunction = try library.createFunction(name: "fragmentFunction").get()
            offscreenRPD.colorAttachments[0].pixelFormat = MTLPixelFormat.bgra8Unorm_srgb
            
            let quadRPD = MTLRenderPipelineDescriptor()
            quadRPD.label = "Draw-in-View Render Pass"
            quadRPD.vertexFunction = try library.createFunction(name: "quadVertexFunction").get()
            quadRPD.fragmentFunction = try library.createFunction(name: "quadFragmentFunction").get()
            quadRPD.colorAttachments[0].pixelFormat = MTLPixelFormat.bgra8Unorm_srgb
            
            self.offscreenRenderPSO = try device.makeRenderPipelineState(descriptor: offscreenRPD)
            self.drawInViewPSO = try device.makeRenderPipelineState(descriptor: quadRPD)
            
            let computeLinesFunction = try library.createFunction(name: "computeLinesFunction").get()
            self.computeLinesPSO = try device.makeComputePipelineState(function: computeLinesFunction)
        }
        catch let error as RendererError {
            return .failure(error)
        }
        catch {
            return .failure(.PipelineCreationError(Details: "Unknown error."))
        }
        
        return .success(Void())
    }
    
    
    private func prepareTextures() -> Result<Void, RendererError> {
        let renderTargetTextureResult = TextureManager.getTexture(with: device,
                                                                  format: .bgra8Unorm_srgb,
                                                                  sizeWH: (Int(data.renderAreaWidth * 2), Int(data.renderAreaHeight * 2)),
                                                                  type: .renderTarget,
                                                                  label: "RenderTargetTexture")
        
        let blurTextureResult = TextureManager.getTexture(with: device,
                                                          format: .bgra8Unorm_srgb,
                                                          sizeWH: (Int(data.renderAreaWidth * 2), Int(data.renderAreaHeight * 2)),
                                                          type: .readWrite,
                                                          label: "BlurTexture")
        
        do {
            self.blurTexture = try blurTextureResult.get()
            self.renderTargetTexture = try renderTargetTextureResult.get()
        }
        catch let error as RendererError {
            return .failure(error)
        }
        catch {
            return .failure(.TextureCreationError(Details: "Unknown error."))
        }
        
        self.offscreenRenderPD = MTLRenderPassDescriptor()
        self.offscreenRenderPD.colorAttachments[0].texture = self.renderTargetTexture
        self.offscreenRenderPD.colorAttachments[0].loadAction = .clear
        self.offscreenRenderPD.colorAttachments[0].storeAction = .store
        self.offscreenRenderPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        
        return .success(Void())
    }
}
