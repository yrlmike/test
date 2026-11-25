import SwiftUI
import ReplayKit
import AVFoundation

// 原生屏幕广播选择器视图 (用于触发录屏)
struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let pickerView = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        pickerView.showsMicrophoneButton = false
        
        // 强烈建议：将下方的字符串换成你 project.yml 里的 Extension Bundle ID
        // 这样点击录屏按钮时，就能直接默认选中你的扩展，不用从列表里找了
        pickerView.preferredExtension = "com.screensolver.app.ScreenSolverExtension"
        
        return pickerView
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var viewModel = SolverViewModel.shared

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
        NavigationView {
            Form {
                // ==========================================
                // 一、画中画与录屏 (最上面)
                // ==========================================
                Section(header: Text("第一步：启动服务")) {
                    Button(action: {
                        PiPManager.shared.startPiP()
                    }) {
                        Text("1. 开启画中画悬浮窗")
                            .bold()
                            // ✅ 修复：让按钮撑满整行，并扩大点击热区
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    // ✅ 修复：防止 Form 内部的按钮被局部事件拦截
                    .buttonStyle(.borderless)
                    
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Text("2. 点击下方黑圈启动屏幕识别")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            
                            BroadcastPickerView()
                                .frame(width: 44, height: 44)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                // ==========================================
                // 二、实时识别内容与结果
                // ==========================================
                Section(header: Text("第二步：实时运行状态")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("大模型最新解答：")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(viewModel.answerText)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Divider().padding(.vertical, 4)
                        
                        Text("屏幕 OCR 提取文本：")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(viewModel.recognizedQuestion.isEmpty ? "等待识别中..." : viewModel.recognizedQuestion)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(6)
                    }
                    .padding(.vertical, 4)
                }

                // ==========================================
                // 三、云端大模型设置
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
                // 四、本地 MLX 模型设置
                // ==========================================
                if useLocalMLX {
                    Section(header: Text("本地 MLX 模型设置")) {
                        Picker("选择模型", selection: $selectedLocalModel) {
                            Text("Qwen2.5-1.5B (极速版)").tag("mlx-community/Qwen2.5-1.5B-Instruct-4bit")
                            Text("Qwen2.5-3B (高精版)").tag("mlx-community/Qwen2.5-3B-Instruct-4bit")
                        }
                        
                        if viewModel.isDownloadingModel {
                            ProgressView(value: viewModel.modelDownloadProgress, total: 1.0)
                            Text(String(format: "正在下载或加载: %.1f%%", viewModel.modelDownloadProgress * 100))
                                .font(.caption).foregroundColor(.gray)
                        } else {
                            Button(action: {
                                viewModel.preloadLocalModel()
                            }) {
                                Text("点击预加载 / 检查模型")
                                    // ✅ 修复：扩大点击热区
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                
                // ==========================================
                // 五、自定义提示词
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
                            // ✅ 修复：扩大点击热区
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("ScreenSolver")
            // ✅ iOS 原生机制：滑动页面即可收起键盘，不再吞噬按钮点击事件
            .scrollDismissesKeyboard(.immediately) 
            .background(
                // ✅ 修复：如果你之前的代码里有用于画中画的隐藏视图层 (比如 PlayerView)，必须挂载在这里
                // 如果没有，这行代码不会有任何负面影响。
                Color.clear 
            )
            .onAppear {
                // ✅ 修复：画中画硬性前置条件：必须激活音频会话，否则画中画引擎会直接拒绝启动
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
                try? AVAudioSession.sharedInstance().setActive(true)
            }
        }
    }
}
