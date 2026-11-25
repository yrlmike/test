import SwiftUI
import ReplayKit // 导入 ReplayKit 以使用原生录屏弹窗

// ✅ 新增：原生屏幕广播选择器视图
struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let pickerView = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        pickerView.showsMicrophoneButton = false
        // 注意：如果你的广播扩展 Target 的 Bundle ID 不是默认的，可以取消下面这行的注释并填入你的扩展 Bundle ID
        // pickerView.preferredExtension = "com.yourname.ScreenSolver.Extension" 
        return pickerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct ContentView: View {
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

    @StateObject private var viewModel = SolverViewModel.shared

    var body: some View {
        NavigationView {
            Form {
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

                if useLocalMLX {
                    Section(header: Text("本地 MLX 模型设置"), footer: Text("首次加载会自动下载，保存至 Documents 目录，不占用 iCloud 空间且永久保留。")) {
                        Picker("选择模型", selection: $selectedLocalModel) {
                            Text("Qwen2.5-1.5B (极速版 ~900MB)").tag("mlx-community/Qwen2.5-1.5B-Instruct-4bit")
                            Text("Qwen2.5-3B (高精版 ~1.8GB)").tag("mlx-community/Qwen2.5-3B-Instruct-4bit")
                        }
                        
                        if viewModel.isDownloadingModel {
                            ProgressView(value: viewModel.modelDownloadProgress, total: 1.0)
                                .progressViewStyle(LinearProgressViewStyle())
                            Text(String(format: "正在下载或加载: %.1f%%", viewModel.modelDownloadProgress * 100))
                                .font(.caption)
                                .foregroundColor(.gray)
                        } else {
                            // 这里修复了无法点击的问题
                            Button("点击预加载 / 检查模型") {
                                viewModel.preloadLocalModel()
                            }
                        }
                    }
                }
                
                Section(header: Text("自定义提示词 (即时生效)")) {
                    TextEditor(text: $customPrompt)
                        .frame(height: 180)
                        .font(.system(size: 14))
                    
                    // 这里修复了无法点击的问题
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
                
                Section(header: Text("画中画与录屏")) {
                    // 第一步：开启画中画
                    Button(action: {
                        PiPManager.shared.startPiP()
                    }) {
                        Text("第一步：开启画中画悬浮窗")
                            .bold()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    
                    // 第二步：原生录屏呼出按钮
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Text("第二步：点击下方黑圈启动屏幕识别")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            
                            // 这个就是弹出的原生的录屏选择器
                            BroadcastPickerView()
                                .frame(width: 44, height: 44)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("ScreenSolver")
            // ✅ 修复方案：移除拦截手势的 onTapGesture，改用 iOS 16+ 的原生滑动收起键盘
            .scrollDismissesKeyboard(.immediately) 
        }
    }
}
