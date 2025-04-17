//
//  Owenisas_MusicApp.swift
//  Owenisas Music
//
//  Created by Thomas Suen on 4/15/25.
//

import SwiftUI

@main
struct Owenisas_MusicApp: App {
    var body: some Scene {
        WindowGroup {
            TabView{
                ContentView()
                    .tabItem {
                        Image(systemName: "house.fill")
                        Text("Home")
                    }
                DownloadView()
                    .tabItem {
                        Image(systemName: "list.bullet.indent")
                        Text("Download")
                    }
            }.tint(.blue)
        }
    }
}
