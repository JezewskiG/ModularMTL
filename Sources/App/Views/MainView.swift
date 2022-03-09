//
//  MainView.swift
//
//
//  Created by Gracjan J on 13/02/2022.
//

import SwiftUI
import ModularMTLCore

struct MainView: View {
    
    @StateObject var data = RendererObservableData()
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            HStack(alignment: .center, spacing: 5) {
                MetalView()
                    .frame(width: (data.width / 2.0) + 28, height: data.height+28)
                UserInterfaceView()
                    .frame(maxWidth: .infinity)
            }
            .ignoresSafeArea(.all, edges: .top)
            .alert("ModularMTL", isPresented: $data.showAlert, actions: {
                Button("Confirm") {
                    if data.status == .MetalUnsupported {
                        exit(1)
                    }
                }
            }, message: {
                Text(data.getStatusMessage())
            })
            
        }
        .environmentObject(data)
        .frame(width: data.width, height: data.height, alignment: .center)
    }
}
