import UIKit

final class KeyboardViewController: UIInputViewController {
    private let containerView = UIView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let configureButton = UIButton(type: .system)
    private let nextKeyboardButton = UIButton(type: .system)

    private var transcriptTimer: Timer?
    private var lastInsertedTranscript = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        updateUI()
        startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPolling()
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        lastInsertedTranscript = ""
        updateUI()
    }

    private func setupViews() {
        view.backgroundColor = UIColor.systemBackground
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(containerView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "BobrWhisper"
        titleLabel.font = UIFont.preferredFont(forTextStyle: .headline)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = UIColor.secondaryLabel
        statusLabel.numberOfLines = 2

        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.setTitle("Start", for: .normal)
        micButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        micButton.setTitleColor(.white, for: .normal)
        micButton.backgroundColor = UIColor.systemRed
        micButton.layer.cornerRadius = 24
        micButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        micButton.addTarget(self, action: #selector(handleMicTap), for: .touchUpInside)

        configureButton.translatesAutoresizingMaskIntoConstraints = false
        configureButton.setTitle("Open BobrWhisper", for: .normal)
        configureButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .subheadline)
        configureButton.addTarget(self, action: #selector(handleOpenApp), for: .touchUpInside)

        nextKeyboardButton.translatesAutoresizingMaskIntoConstraints = false
        nextKeyboardButton.setTitle("Next", for: .normal)
        nextKeyboardButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .subheadline)
        nextKeyboardButton.addTarget(self, action: #selector(handleNextKeyboard), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, micButton, configureButton, nextKeyboardButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(stack)

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.topAnchor.constraint(equalTo: view.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            stack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: containerView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor, constant: -16)
        ])
    }

    private func updateUI() {
        let state = KeyboardStateSnapshot()
        let hasModelFile = state.selectedModelFilename.map {
            FileManager.default.fileExists(atPath: KeyboardSharedState.modelsDirectory().appendingPathComponent($0).path)
        } ?? false
        let canRecord = state.isModelLoaded && hasModelFile

        micButton.isEnabled = canRecord
        micButton.alpha = canRecord ? 1.0 : 0.5
        micButton.backgroundColor = state.isRecording ? UIColor.systemGray : UIColor.systemRed
        micButton.setTitle(state.isRecording ? "Stop" : "Start", for: .normal)

        configureButton.isHidden = canRecord

        if !canRecord {
            statusLabel.text = "Open BobrWhisper to download and load a model."
            return
        }

        if state.isRecording {
            statusLabel.text = "Recording…"
        } else {
            statusLabel.text = "Ready"
        }
    }

    private func startPolling() {
        transcriptTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(handlePoll), userInfo: nil, repeats: true)
    }

    private func stopPolling() {
        transcriptTimer?.invalidate()
        transcriptTimer = nil
    }

    @objc private func handlePoll() {
        updateUI()
        let state = KeyboardStateSnapshot()
        guard !state.transcript.isEmpty else {
            return
        }
        guard state.transcript != lastInsertedTranscript else { return }
        let delta = state.transcript.replacingPrefix(lastInsertedTranscript)
        guard !delta.isEmpty else {
            lastInsertedTranscript = state.transcript
            return
        }
        textDocumentProxy.insertText(delta)
        lastInsertedTranscript = state.transcript
    }

    @objc private func handleMicTap() {
        handleOpenApp()
    }

    @objc private func handleOpenApp() {
        let url = URL(string: "bobrwhisper://record")
        if let url = url {
            extensionContext?.open(url, completionHandler: nil)
        }
    }

    @objc private func handleNextKeyboard() {
        advanceToNextInputMode()
    }
}

private extension String {
    func replacingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }
}
