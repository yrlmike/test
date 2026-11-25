import SwiftUI
import ReplayKit
import AVFoundation

// 原生屏幕广播选择器视图
struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let pickerView = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        pickerView.showsMicrophoneButton = false
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
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    
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
                // 二、实时识别内容与结果 (恢复原有的查看区域)
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
                            .lineLimit(6) // 限制行数防止占用太大屏幕
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
                            Button("点击预加载 / 检查模型") {
                                viewModel.preloadLocalModel()
                            }
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
                    
                    Button("恢复默认指令") {
                        customPrompt = """
                        你是一个手机悬浮窗极速答题助手。用户发来的是考试页面文本（同屏可能包含1到3道连续的选择题）。
                        请严格遵守以下规则：
                        1. 严禁使用任何Markdown符号（不要出现**、*、#、`、-等）。
                        2. 按屏幕从上到下的顺序，识别出所有【题干和选项都完整】的题目，逐题输出答案，每题占一行。
                        3. 每行严格按此格式：「题干前4~6个核心字：选项字母」（例如：抗酸剂监护：ABCD）。
                        4. 屏幕最上方或最下方若有残缺题目，直接忽略。
                        5. 绝不要写任何解析，确保3秒内一眼看清所有选项。
                        """
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("ScreenSolver")
            .scrollDismissesKeyboard(.immediately) // 解决输入框导致按键失效的问题
            .onAppear {
                // 确保音频会话激活，这是 iOS 画中画弹出的硬性前提条件
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: .mixWithOthers)
                try? AVAudioSession.sharedInstance().setActive(true)
            }
        }
    }
}
