import SwiftUI
import ReplayKit

struct ContentView: View {
    @StateObject private var vm = SolverViewModel.shared
    @StateObject private var pip = PiPManager.shared // ✅ 恢复你历史代码中的 pip 引用

    @AppStorage("useLocalMLX") var useLocalMLX: Bool = false
    @AppStorage("selectedLocalModel") var selectedLocalModel: String = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    
    @AppStorage("apiBaseURL") var apiBaseURL: String = "https://tokenhub.tencentmaas.com/v1"
    @AppStorage("apiKey") var apiKey: String = ""
    @AppStorage("apiModelName") var apiModelName: String = "kimi-k3.1-pro"
    
    @AppStorage("customPrompt") var customPrompt: String = """
    你是一个手机悬浮窗极速答题助手。用户发来的是考试页面文本（同屏可能包含1到3道连续的选择题）。
    请严格遵守以下规则：
    1. 严禁使用任何Markdown符号（不要出现**、*、#、`、-等）。
    2. 按屏幕从上到下的顺序，识别出所有【题干和选项都完整】的题目，逐题输出答案，每题占一行。
    3. 每行严格按此格式：「题干前4~6个核心字：选项字母」（例如：抗酸剂监护：ABCD）。
    4. 屏幕最上方或最下方若有残缺题目，直接忽略。
    5. 绝不要写任何解析，确保3秒内一眼看清所有选项。
    """

    var body: some View {
        NavigationStack {
            ZStack {
                // ✅ 核心修复 1：恢复你的隐形 PiP 视频层
                PiPHostView()
                    .frame(width: 320, height: 180)
                    .opacity(0.01)

                Form {
                    // ==========================================
                    // 1. 核心控制区 (结合你的历史逻辑与大热区按钮)
                    // ==========================================
                    Section(header: Text("第一步：启动服务")) {
                        Button(action: {
                            if pip.isPiPActive {
                                pip.stopPiP()
                            } else {
                                pip.startPiP()
                            }
                        }) {
                            HStack {
                                Image(systemName: pip.isPiPActive ? "pip.exit" : "pip.enter")
                                Text(pip.isPiPActive ? "关闭答案悬浮窗 (PiP)" : "开启答案悬浮窗 (PiP)")
                                    .bold()
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .tint(pip.isPiPActive ? .red : .blue)
                        
                        HStack {
                            Image(systemName: "record.circle").foregroundColor(.red)
                            Text("开启全局屏幕识别").bold()
                            Spacer()
                            // ✅ 核心修复 2：恢复你的动态扩展 Bundle ID 获取逻辑
                            BroadcastPickerRepresentable(
                                extensionBundleID: "\(Bundle.main.bundleIdentifier ?? "").ScreenSolverExtension"
                            )
                            .frame(width: 44, height: 44)
                        }
                        .padding(.vertical, 4)
                        
                        Text("提示：先点上方「开启答案悬浮窗」，再点右侧录屏图标选择本 App 开始直播，随后切到其他 App 即可自动识别。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // ==========================================
                    // 2. 实时识别与结果预览 (恢复显示区)
                    // ==========================================
                    Section(header: Text("第二步：实时运行状态")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("大模型最新解答：")
                                .font(.caption)
                                .foregroundColor(.gray)
                            
                            if vm.isThinking {
                                HStack {
                                    ProgressView().padding(.trailing, 4)
                                    Text(vm.answerText).font(.system(size: 15, weight: .bold)).foregroundColor(.blue)
                                }
                            } else {
                                Text(vm.answerText).font(.system(size: 15, weight: .bold)).foregroundColor(.blue)
                            }
                            
                            Divider().padding(.vertical, 4)
                            
                            Text("屏幕 OCR 提取文本：")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text(vm.recognizedQuestion.isEmpty ? "等待识别中..." : vm.recognizedQuestion)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(6)
                        }
                        .padding(.vertical, 4)
                    }

                    // ==========================================
                    // 3. 云端大模型设置
                    // ==========================================
                    Section(header: Text("云端大模型设置")) {
                        Toggle("优先使用本地 MLX 离线模型", isOn: $useLocalMLX)
                        
                        if !useLocalMLX {
                            TextField("API Base URL", text: $apiBaseURL)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            
                            SecureField("API Key (sk-...)", text: $apiKey)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            
                            TextField("模型名称 (如 kimi-k3.1-pro)", text: $apiModelName)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                    }

                    // ==========================================
                    // 4. 本地 MLX 模型设置
                    // ==========================================
                    if useLocalMLX {
                        Section(header: Text("本地 MLX 模型设置")) {
                            Picker("选择模型", selection: $selectedLocalModel) {
                                Text("Qwen2.5-1.5B (极速版)").tag("mlx-community/Qwen2.5-1.5B-Instruct-4bit")
                                Text("Qwen2.5-3B (高精版)").tag("mlx-community/Qwen2.5-3B-Instruct-4bit")
                            }
                            
                            if vm.isDownloadingModel {
                                ProgressView(value: vm.modelDownloadProgress, total: 1.0)
                                Text(String(format: "正在下载或加载: %.1f%%", vm.modelDownloadProgress * 100))
                                    .font(.caption).foregroundColor(.gray)
                            } else {
                                Button(action: {
                                    vm.preloadLocalModel()
                                }) {
                                    Text("点击预加载 / 检查模型")
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    
                    // ==========================================
                    // 5. 自定义提示词
                    // ==========================================
                    Section(header: Text("自定义提示词 (即时生效)")) {
                        TextEditor(text: $customPrompt)
                            .frame(height: 150)
                            .font(.system(size: 13))
                        
                        Button(action: {
                            customPrompt = """
                            你是一个手机悬浮窗极速答题助手。用户发来的是考试页面文本（同屏可能包含1到3道连续的选择题）。
                            请严格遵守以下规则：
                            1. 严禁使用任何Markdown符号（不要出现**、*、#、`、-等）。
                            2. 按屏幕从上到下的顺序，识别出所有【题干和选项都完整】的题目，逐题输出答案，每题占一行。
                            3. 每行严格按此格式：「题干前4~6个核心字：选项字母」（例如：抗酸剂监护：ABCD）。
                            4. 屏幕最上方或最下方若有残缺题目，直接忽略。
                            5. 绝不要写任何解析，确保3秒内一眼看清所有选项。
                            """
                        }) {
                            Text("恢复默认指令")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("ScreenSolver")
            .scrollDismissesKeyboard(.immediately)
            .onAppear {
                // ✅ 核心修复 3：调用你自己的环境初始化方法
                pip.setupAudioAndPiP()
            }
        }
    }
}

// ✅ 恢复你的原生录屏控件封装
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
