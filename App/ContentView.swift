import SwiftUI

struct ContentView: View {
    // === 核心状态变量 (存储在 AppStorage 中，重签不丢数据) ===
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
    5. 解析越短越好，确保3秒内一眼看清所有选项。
    """

    @StateObject private var viewModel = SolverViewModel.shared

    var body: some View {
        NavigationView {
            Form {
                // 1. 云端模型配置
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

                // 2. 本地离线模型配置
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
                            Button("点击预加载 / 检查模型") {
                                viewModel.preloadLocalModel()
                            }
                        }
                    }
                }
                
                // 3. 提示词动态配置
                Section(header: Text("自定义提示词 (即时生效)")) {
                    TextEditor(text: $customPrompt)
                        .frame(height: 180)
                        .font(.system(size: 14))
                    
                    Button("恢复默认指令") {
                        customPrompt = """
                        你是一个手机悬浮窗极速答题助手。用户发来的是考试页面文本（同屏可能包含1到3道连续的选择题）。
                        请严格遵守以下规则：
                        1. 严禁使用任何Markdown符号（不要出现**、*、#、`、-等）。
                        2. 按屏幕从上到下的顺序，识别出所有【题干和选项都完整】的题目，逐题输出答案，每题占一行。
                        3. 每行严格按此格式：「题干前4~6个核心字：选项字母」（例如：抗酸剂监护：ABCD）。
                        4. 屏幕最上方或最下方若有残缺题目，直接忽略。
                        5. 解析越短越好，确保3秒内一眼看清所有选项。
                        """
                    }
                    .foregroundColor(.red)
                }
                
                // 4. 画中画功能控制
                Section(header: Text("画中画与录屏")) {
                    Button(action: {
                        PiPManager.shared.startPiP()
                    }) {
                        Text("开启画中画悬浮窗")
                            .bold()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    
                    Text("提示: 开启画中画后，请在控制中心长按“屏幕录制”按钮，选择 ScreenSolver 扩展开始答题。")
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle("ScreenSolver")
            .onTapGesture {
                // 点击空白处收起键盘
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }
}
