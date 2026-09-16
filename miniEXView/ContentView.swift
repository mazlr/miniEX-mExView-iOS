import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel; @State private var showConnection = false; @State private var showAbout = false; @State private var shareURL: URL?
    var body: some View {
        NavigationView { TabView {
            RemoteView().tabItem { Label("Remote Control", systemImage: "display") }
            SettingsView().tabItem { Label("Device", systemImage: "slider.horizontal.3") }
            DataView(shareURL: $shareURL).tabItem { Label("Data", systemImage: "tablecells") }
            DiagnosticsView().tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
        }.navigationTitle("miniEXPLONIX View").toolbar { ToolbarItem(placement: .navigationBarTrailing) { Menu {
            Button("Connection") { showConnection = true }; Button("About") { showAbout = true }; Button("Offline demo") { model.demo() }; Divider(); Button(model.isConnected ? "Disconnect" : "Connect via Wi-Fi") { model.isConnected ? model.disconnect() : model.connect() }
        } label: { Image(systemName: "ellipsis.circle") } } }.sheet(isPresented: $showConnection) { ConnectionView() }.sheet(isPresented: $showAbout) { AboutView() }.sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) { if let shareURL { ShareView(url: shareURL) } } }
    }
}

struct RemoteView: View {
    @EnvironmentObject var model: AppModel; @State private var zoom = 1.0; @State private var touchingDeviceKey = false
    @State private var recording: OfflineRecording = .short
    var body: some View { ScrollView { VStack(spacing: 14) {
        Text(model.connectionState).font(.caption).foregroundStyle(model.isConnected ? .green : .secondary)
        Group {
            if let image = model.displayImage { Image(uiImage: image).resizable().interpolation(.none) }
            else if model.isOfflineDemo { Canvas { context, size in let sx = size.width/160, sy = size.height/128; for y in 0..<128 { for x in 0..<160 { context.fill(Path(CGRect(x:CGFloat(x)*sx,y:CGFloat(y)*sy,width:sx+0.5,height:sy+0.5)),with:.color(model.pixels[y*160+x])) } } } }
            else { Color.black }
        }.aspectRatio(160.0/128.0,contentMode:.fit).background(.black).clipShape(RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(.gray,lineWidth:5)).scaleEffect(zoom).gesture(MagnificationGesture().onChanged { zoom = min(max($0,1),4) })
        Button(model.remoteActive ? "RC OFF" : "RC ON") { model.toggleRemote() }.buttonStyle(.borderedProminent).disabled(!model.isConnected)
        if model.isOfflineDemo {
            Picker("Recording", selection: $recording) {
                ForEach(OfflineRecording.allCases) { item in Text(item.title).tag(item) }
            }
            HStack {
                Button("Play recording") { model.playOffline(recording) }.disabled(model.replayPlaying)
                if model.replayPlaying { Button("Stop") { model.cancelReplay() } }
            }.buttonStyle(.bordered)
            if model.replayTotal > 0 {
                ProgressView(value: Double(model.replayProgress), total: Double(model.replayTotal))
                Text("\(model.replayProgress) / \(model.replayTotal) frames").font(.caption)
            }
        }
        Image(touchingDeviceKey ? "SpeedKeyDown" : "SpeedKeyUp")
            .resizable().scaledToFit().frame(width: 120, height: 120)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !touchingDeviceKey { touchingDeviceKey = true; model.pressDeviceKey() }
                }
                .onEnded { _ in touchingDeviceKey = false; model.releaseDeviceKey() })
            .allowsHitTesting(model.isConnected)
            .opacity(model.isConnected ? 1 : 0.5)
            .accessibilityLabel("Device button")
        Button("Redraw display") { model.sendCM(WireMessage.redraw, target: 2) }
            .disabled(!model.isConnected)
        Text(model.status).font(.footnote).foregroundStyle(.secondary)
    }.padding() }.onDisappear { touchingDeviceKey = false; model.releaseDeviceKey() } }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { Form { Section("Device") { HStack { Text("Firmware"); Spacer(); Text(model.firmware).foregroundColor(.secondary) }; HStack { Text("Serial number"); Spacer(); Text(model.serial).foregroundColor(.secondary) }; Picker("Mode",selection:$model.parameters.mode) { Text("Wide Range").tag(0); Text("Advanced").tag(1); Text("TATP").tag(2) }; Toggle("Wi‑Fi flag",isOn:$model.parameters.wifi) }
        threshold("Wide Range",zero:$model.parameters.wideZero,alarm:$model.parameters.wideAlarm); threshold("Advanced",zero:$model.parameters.advancedZero,alarm:$model.parameters.advancedAlarm); threshold("TATP",zero:$model.parameters.tatpZero,alarm:$model.parameters.tatpAlarm)
        Section("Languages") {
            Picker("Primary language", selection: $model.parameters.primaryLanguage) { ForEach(model.supportedLanguages, id: \.self) { id in Text(model.languageName(id)).tag(id) } }
            Picker("Secondary language", selection: $model.parameters.secondaryLanguage) { ForEach(model.supportedLanguages, id: \.self) { id in Text(model.languageName(id)).tag(id) } }
        }
        Section("Time and sound") { value("Time to OFF",$model.parameters.offTime); value("Sampling Period",$model.parameters.sampling); value("Beep Volume",$model.parameters.beep); value("Alarm Volume",$model.parameters.alarm); value("IR Sampling Power",$model.parameters.irPower) }
        Section { Button("Read from device") { model.refreshSettings() }; Button("Save to device") { model.saveSettings() }.disabled(!model.isConnected); Button("Restore factory defaults",role:.destructive) { model.restoreDefaults() }.disabled(!model.isConnected) }
    }.background(KeyboardDismissArea()) }
    private func threshold(_ title:String,zero:Binding<Double>,alarm:Binding<Double>)->some View { Section(title) { value("Zero threshold",zero); value("Alarm threshold",alarm) } }
    private func value(_ title:String,_ binding:Binding<Double>)->some View { HStack { Text(title); Spacer(); TextField(title,value:binding,format:.number).multilineTextAlignment(.trailing).keyboardType(.decimalPad).frame(width:110) } }
}

struct DataView: View {
    @EnvironmentObject var model: AppModel; @Binding var shareURL: URL?; @State private var confirmErase=false
    var body: some View { VStack { HStack { Button("Download") { model.refreshData() }; Button("Export TSV") { shareURL=model.exportTSV() }.disabled(model.records.isEmpty); Button("Erase",role:.destructive) { confirmErase=true }.disabled(!model.isConnected) }.buttonStyle(.bordered).padding(.top)
        List(model.records) { r in HStack { Text("\(r.index)").frame(width:35,alignment:.leading); VStack(alignment:.leading) { Text(r.timestamp,style:.date); Text(r.timestamp,style:.time).font(.caption); Text("Mode \(r.mode) · \(Double(r.period)/8, specifier: "%.1f") s").font(.caption2) }; Spacer(); Text(r.value,format:.number.precision(.fractionLength(3))); if r.alarm { Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.red) } } }
    }.confirmationDialog("Erase all stored records on the device?",isPresented:$confirmErase,titleVisibility:.visible) { Button("Erase",role:.destructive) { model.eraseData() } } }
}

struct ConnectionView: View {
    @EnvironmentObject var model: AppModel; @Environment(\.dismiss) var dismiss
    var body: some View { NavigationView { Form { Section("Wi‑Fi / TCP") { TextField("IP address",text:$model.host).autocapitalization(.none).keyboardType(.numbersAndPunctuation); TextField("Port",value:$model.port,format:.number).keyboardType(.numberPad); Button("Connect") { model.connect(); dismiss() } }
        Section("Internet bridge") { TextField("Server",text:$model.bridgeHost).autocapitalization(.none); TextField("Port",value:$model.bridgePort,format:.number); TextField("32-character device ID",text:$model.deviceID); Button("Connect via bridge") { model.connect(bridge:true); dismiss() }.disabled(model.deviceID.count != 32) }
        Section("Remote Control") { Picker("RC bitmap language",selection:$model.rcLanguage) { ForEach(["English","Japanese","Arabic","TraditionalChinese","SimplifiedChinese","German","Polish"],id:\.self) { Text($0 == "TraditionalChinese" ? "Traditional Chinese" : $0 == "SimplifiedChinese" ? "Simplified Chinese" : $0).tag($0) } }.onChange(of: model.rcLanguage) { _ in model.changeRCLanguage() } }
        Section { Text("USB connection is unavailable on iOS.").foregroundStyle(.secondary) }
    }.navigationTitle("Connection").toolbar { Button("Done") { dismiss() } } } }
}

struct ShareView: UIViewControllerRepresentable { let url:URL; func makeUIViewController(context:Context)->UIActivityViewController { UIActivityViewController(activityItems:[url],applicationActivities:nil) }; func updateUIViewController(_ uiViewController:UIActivityViewController,context:Context){} }

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    private var version: String { "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))" }
    var body: some View { NavigationView { Form {
        Section { HStack { Image("AppIconPreview").resizable().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading) { Text("miniEXPLONIX View").font(.headline); Text("Version \(version)").foregroundStyle(.secondary) } } }
        Section("Connection") { Text("Wi‑Fi / TCP, iOS 15+"); Text("RC display uses the selected language bitmaps.") }
    }.navigationTitle("About").toolbar { Button("Done") { dismiss() } } } }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @State private var shareLog = false
    var body: some View { VStack(spacing: 0) {
        Form {
            Section("Socket") { HStack { Text("State"); Spacer(); Text(model.connectionState).foregroundColor(model.isConnected ? .green : .secondary) }; HStack { Text("Endpoint"); Spacer(); Text(model.activeEndpoint).font(.caption.monospaced()) } }
            Section("Counters") { HStack { Text("Sent to TCP"); Spacer(); Text("\(model.bytesSent) B") }; HStack { Text("Queued"); Spacer(); Text("\(model.bytesQueued) B") }; HStack { Text("Received"); Spacer(); Text("\(model.bytesReceived) B") }; HStack { Text("Packets / CM"); Spacer(); Text("\(model.packetCount) / \(model.cmMessageCount)") } }
            Section("Log file") { Text(model.diagnosticFileURL.lastPathComponent).font(.caption.monospaced()); Button("Share complete log") { shareLog = true }; Text("Files → On My iPhone → miniEXPLONIX View → miniEX-logs").font(.caption).foregroundStyle(.secondary) }
            Section { HStack { Button("Copy log") { UIPasteboard.general.string = model.diagnosticText }; Spacer(); Button("Clear", role: .destructive) { model.clearDiagnostics() } } }
        }.frame(height: 420)
        ScrollView { Text(model.diagnosticText.isEmpty ? "No events yet." : model.diagnosticText).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding() }.background(Color.black).foregroundColor(.green)
    }.sheet(isPresented: $shareLog) { ShareView(url: model.diagnosticFileURL) } }
}

private struct KeyboardDismissArea: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        DispatchQueue.main.async {
            guard let parent = view.superview else { return }
            let gesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dismiss))
            gesture.cancelsTouchesInView = false
            gesture.delegate = context.coordinator
            parent.addGestureRecognizer(gesture)
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        @objc func dismiss() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view: UIView? = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }
    }
}
