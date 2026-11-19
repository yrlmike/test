import SwiftUI
import ReplayKit

struct ContentView: View {
    @StateObject private var vm = SolverViewModel.shared
    @StateObject private var pip = PiPManager.shared

    var body: some View {
        NavigationStack {
            ZStack {
                // 隐形 PiP 视频层（必须存在于屏幕视图层级中，大小为 1x1 像素）
                PiPHostView()
                    .frame(width: 1, height: 1)
                    .opacity(0.01)

                Form {
                    // 1. 核心控制区
                    Section("第一步：启动悬浮窗与屏幕监测") {
                        Button {
                            if pip.isPiPActive {
                                pip.stopPiP()
                            } else {
                                pip.startPiP()
                            }
                        } label: {
                            HStack {
                                Image(systemName: pip.isPiPActive ? "pip.exit" : "pip.enter")
                                Text(pip.isPiPActive ? "关闭答案悬浮窗 (PiP)" : "开启答案悬浮窗 (PiP)")
                                    .fontWeight(.semibold)
                            }
                        }
                        .tint(pip.isPiPActive ? .red : .blue)

                        HStack {
                            Image(systemName: "record.circle")
                                .foregroundColor(.red)
                            Text("开启全局屏幕识别")
                                .fontWeight(.semibold)
                            Spacer()
                            // ⚠️ 替换为你实际的 Extension Bundle ID
                            BroadcastPickerRepresentable(
                                extensionBundleID: "\(Bundle.main.bundleIdentifier ?? "").ScreenSolverExtension"
                            )
                            .frame(width: 44, height: 44)
                        }

                        Text("提示：先点上方「开启答案悬浮窗」，再点右侧录屏图标选择本 App 开始直播，随后切到其他 App 即可自动识别。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // 2. 实时识别与结果预览
                    Section("实时识别与答案") {
                        if vm.isThinking {
                            HStack {
                                ProgressView()
                                Text("正在生成答案...")
                                    .foregroundColor(.secondary)
                            }
                        }

                        Text(vm.answerText)
                            .font(.body)
                            .textSelection(.enabled)

                        if !vm.recognizedQuestion.isEmpty {
                            DisclosureGroup("查看最近 OCR 原文") {
                                Text(vm.recognizedQuestion)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // 3. 推理引擎配置
                    Section("推理引擎设置（云端 / 本地 MLX 离线）") {
                        Toggle("优先使用本地 MLX 离线模型", isOn: $vm.useLocalMLX)

                        if vm.useLocalMLX || vm.apiKey.isEmpty {
                            Picker("本地模型", selection: $vm.selectedLocalModelRaw) {
                                ForEach(LocalLLMService.AvailableModel.allCases) { model in
                                    Text(model.displayName).tag(model.rawValue)
                                }
                            }

                            Button("预下载 / 加载本地模型") {
                                vm.preloadLocalModel()
                            }

                            if vm.isDownloadingModel {
                                ProgressView(value: vm.modelDownloadProgress) {
                                    Text("模型下载中: \(Int(vm.modelDownloadProgress * 100))%")
                                        .font(.caption)
                                }
                            }
                        }

                        if !vm.useLocalMLX {
                            TextField("API Base URL", text: $vm.apiBaseURL)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                            SecureField("API Key (未填则自动切本地 MLX)", text: $vm.apiKey)
                            TextField("模型名称", text: $vm.apiModelName)
                                .autocapitalization(.none)
                        }
                    }
                }
            }
            .navigationTitle("ScreenSolver")
            .onAppear {
                pip.setupAudioAndPiP()
            }
        }
    }
}

// 封装 ReplayKit 原生录屏启动按钮
struct BroadcastPickerRepresentable: UIViewRepresentable {
    let extensionBundleID: String

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = extensionBundleID
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}