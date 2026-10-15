import Cocoa
import AltSign

final class ManagedApplicationsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate
{
    private struct Status
    {
        let message: String
        let isError: Bool
    }

    private let devicePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let reloadButton = NSButton(title: "重新读取", target: nil, action: nil)
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "请选择已连接的 iPhone 或 iPad。")
    private let refreshSelectedButton = NSButton(title: "续签所选", target: nil, action: nil)
    private let refreshAllButton = NSButton(title: "续签全部", target: nil, action: nil)
    private let updateButton = NSButton(title: "选择 IPA 更新…", target: nil, action: nil)
    private let dropView = ManagedIPADropView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "读取手机上的签名应用与描述文件。")
    private let progressIndicator = NSProgressIndicator()
    private var devices = [ALTDevice]()
    private var applications = [ManagedApplication]()
    private var deviceObservers = [NSObjectProtocol]()
    private var countdownTimer: Timer?
    private weak var credentialAppleIDField: NSTextField?
    private weak var credentialPasswordField: NSSecureTextField?
    private weak var credentialSubmitButton: NSButton?

    private var isBusy = false
    {
        didSet { self.updateControls() }
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private var selectedDevice: ALTDevice?
    {
        let index = self.devicePicker.indexOfSelectedItem
        return self.devices.indices.contains(index) ? self.devices[index] : nil
    }

    private var selectedApplications: [ManagedApplication]
    {
        self.tableView.selectedRowIndexes.compactMap { index in
            self.applications.indices.contains(index) ? self.applications[index] : nil
        }
    }

    init()
    {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "AltServer · 管理应用"
        window.contentMinSize = NSSize(width: 800, height: 680)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        self.buildInterface()
        window.center()

        for name in [Notification.Name.deviceManagerDeviceDidConnect, .deviceManagerDeviceDidDisconnect]
        {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self = self, !self.isBusy else { return }
                self.reloadDevices()
            }
            self.deviceObservers.append(observer)
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateCountdowns()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.countdownTimer = timer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit
    {
        self.countdownTimer?.invalidate()
        self.deviceObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func present()
    {
        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        if !self.isBusy { self.reloadDevices() }
    }

    private func buildInterface()
    {
        guard let contentView = self.window?.contentView else { return }
        let title = NSTextField(labelWithString: "管理已签名应用")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "本页从手机上的描述文件读取实际到期时间。通过电脑续签后，AltStore「My Apps」可能仍显示旧日期；请以本页重新读取的到期时间为准。")
        subtitle.textColor = .secondaryLabelColor

        self.devicePicker.target = self
        self.devicePicker.action = #selector(deviceChanged)
        self.devicePicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.reloadButton.target = self
        self.reloadButton.action = #selector(reloadDevices)
        let deviceRow = NSStackView(views: [NSTextField(labelWithString: "设备"), self.devicePicker, self.reloadButton])
        deviceRow.orientation = .horizontal
        deviceRow.spacing = 12
        self.devicePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.allowsMultipleSelection = true
        self.tableView.allowsEmptySelection = true
        self.tableView.usesAlternatingRowBackgroundColors = true
        self.tableView.rowHeight = 50
        self.tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (identifier, heading, width) in [("application", "应用 / 签名标识", CGFloat(440)),
                                             ("version", "版本", CGFloat(110)),
                                             ("expiration", "实际到期时间 / 剩余时间", CGFloat(240))]
        {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = heading
            column.width = width
            column.minWidth = identifier == "application" ? 280 : (identifier == "expiration" ? 180 : 90)
            self.tableView.addTableColumn(column)
        }
        scrollView.documentView = self.tableView
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        self.emptyLabel.textColor = .secondaryLabelColor
        self.emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(self.emptyLabel)
        NSLayoutConstraint.activate([
            self.emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            self.emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        for button in [self.refreshSelectedButton, self.refreshAllButton, self.updateButton]
        {
            button.bezelStyle = .rounded
            button.target = self
        }
        self.refreshSelectedButton.action = #selector(refreshSelected)
        self.refreshAllButton.action = #selector(refreshAll)
        self.updateButton.action = #selector(chooseIPA)
        let actions = NSStackView(views: [self.refreshSelectedButton, self.refreshAllButton, self.updateButton, NSView()])
        actions.orientation = .horizontal
        actions.spacing = 12

        self.dropView.onDrop = { [weak self] url in self?.inspectIPA(at: url) }
        self.dropView.onRejection = { [weak self] message in self?.setStatus(message, isError: true) }
        self.dropView.heightAnchor.constraint(equalToConstant: 96).isActive = true

        self.progressIndicator.style = .spinning
        self.progressIndicator.controlSize = .small
        self.progressIndicator.isDisplayedWhenStopped = false
        self.progressIndicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
        self.progressIndicator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        self.statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.statusLabel.maximumNumberOfLines = 3
        let statusRow = NSStackView(views: [self.progressIndicator, self.statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = 10
        statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let stack = NSStackView(views: [title, subtitle, deviceRow, scrollView, actions, self.dropView, statusRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])
        for view in [subtitle, deviceRow, scrollView, actions, self.dropView, statusRow]
        {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        self.updateControls()
    }

    private func setStatus(_ message: String, isError: Bool = false)
    {
        self.statusLabel.stringValue = message
        self.statusLabel.toolTip = message
        self.statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func errorMessage(_ error: Error) -> String
    {
        let error = error as NSError
        var messages = [String]()
        for value in [error.localizedDescription, error.localizedFailureReason, error.localizedRecoverySuggestion]
        {
            guard let message = value?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty,
                  !messages.contains(where: { $0.localizedCaseInsensitiveContains(message) }) else { continue }
            messages.append(message)
        }
        return messages.joined(separator: "\n")
    }

    private func updateControls()
    {
        let hasApplications = self.selectedDevice != nil && !self.applications.isEmpty
        self.devicePicker.isEnabled = !self.isBusy && !self.devices.isEmpty
        self.reloadButton.isEnabled = !self.isBusy
        self.tableView.isEnabled = !self.isBusy
        self.refreshSelectedButton.isEnabled = !self.isBusy && hasApplications && !self.selectedApplications.isEmpty
        self.refreshAllButton.isEnabled = !self.isBusy && hasApplications
        self.updateButton.isEnabled = !self.isBusy && hasApplications
        self.dropView.isEnabled = !self.isBusy && hasApplications
        self.emptyLabel.isHidden = !self.applications.isEmpty
        self.emptyLabel.stringValue = self.isBusy ? "正在读取应用…" : "未发现可管理的签名应用。"
        if self.isBusy { self.progressIndicator.startAnimation(nil) }
        else { self.progressIndicator.stopAnimation(nil) }
    }

    @objc private func reloadDevices()
    {
        guard !self.isBusy else { return }
        let previousIdentifier = self.selectedDevice?.identifier
        self.devices = ALTDeviceManager.shared.availableDevices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.devicePicker.removeAllItems()
        self.devices.forEach { self.devicePicker.addItem(withTitle: $0.name) }
        if let index = self.devices.firstIndex(where: { $0.identifier == previousIdentifier })
        {
            self.devicePicker.selectItem(at: index)
        }
        self.applications = []
        self.tableView.reloadData()
        guard self.selectedDevice != nil else
        {
            self.updateControls()
            self.setStatus("未发现已连接的设备。请连接并解锁 iPhone 或 iPad，再点击「重新读取」。")
            return
        }
        self.reloadApplications()
    }

    @objc private func deviceChanged()
    {
        guard !self.isBusy else { return }
        self.applications = []
        self.tableView.reloadData()
        self.reloadApplications()
    }

    private func reloadApplications(finalStatus: Status? = nil)
    {
        guard let device = self.selectedDevice else { return }
        let selectedIdentifiers = Set(self.selectedApplications.map(\.bundleIdentifier))
        self.isBusy = true
        self.setStatus("正在读取「\(device.name)」的应用和描述文件…")
        ALTDeviceManager.shared.fetchManagedApplications(on: device) { [weak self] result in
            guard let self = self else { return }
            switch result
            {
            case .success(let applications):
                self.applications = applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.tableView.reloadData()
                self.tableView.selectRowIndexes(IndexSet(self.applications.indices.filter {
                    selectedIdentifiers.contains(self.applications[$0].bundleIdentifier)
                }), byExtendingSelection: false)
                self.isBusy = false
                if let status = finalStatus
                {
                    self.setStatus(status.message + " 已重新读取手机上的描述文件。", isError: status.isError)
                }
                else
                {
                    self.setStatus("已读取 \(applications.count) 个签名应用。可按住 Command 多选后续签，或拖入一个 IPA 更新。")
                }
            case .failure(let error):
                self.isBusy = false
                let prefix = finalStatus.map { $0.message + "\n" } ?? ""
                self.setStatus(prefix + "读取手机应用失败：" + self.errorMessage(error), isError: true)
            }
        }
    }

    @objc private func refreshSelected() { self.refresh(self.selectedApplications) }
    @objc private func refreshAll() { self.refresh(self.applications) }

    private func refresh(_ applications: [ManagedApplication])
    {
        guard !self.isBusy, let device = self.selectedDevice, !applications.isEmpty else { return }
        self.isBusy = true
        let identifiers = applications.map(\.bundleIdentifier)
        let names = applications.map(\.name).joined(separator: "、")
        self.setStatus("准备续签：\(names)。")
        self.requestCredentials(title: "续签 \(applications.count) 个应用", details: "设备：\(device.name)\n应用：\(names)", submitTitle: "续签") { [weak self] appleID, password in
            guard let self = self else { return }
            self.setStatus("正在续签 \(applications.count) 个应用，请保持设备连接…")
            ALTDeviceManager.shared.refreshManagedApplications(identifiers, on: device, appleID: appleID, password: password) { [weak self] result in
                guard let self = self else { return }
                switch result
                {
                case .success(let refreshed):
                    let completed = Set(refreshed.map(\.bundleIdentifier))
                    let expected = Set(identifiers)
                    let succeeded = expected.isSubset(of: completed)
                    let status = succeeded ? "所选 \(applications.count) 个应用已续签。" : "返回的续签结果不完整，请检查下面各应用的实际到期时间。"
                    self.reloadApplications(finalStatus: Status(message: status, isError: !succeeded))
                case .failure(let error):
                    self.reloadApplications(finalStatus: Status(message: "续签失败：" + self.errorMessage(error), isError: true))
                }
            }
        }
    }

    @objc private func chooseIPA()
    {
        guard !self.isBusy, let window = self.window else { return }
        let panel = NSOpenPanel()
        panel.title = "选择用于更新已安装应用的 IPA"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["ipa"]
        self.isBusy = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            self.isBusy = false
            guard response == .OK, let url = panel.url else
            {
                self.setStatus("已取消选择 IPA。")
                return
            }
            self.inspectIPA(at: url)
        }
    }

    private func inspectIPA(at url: URL)
    {
        guard !self.isBusy, let device = self.selectedDevice else { return }
        guard url.isFileURL, url.pathExtension.lowercased() == "ipa" else
        {
            self.setStatus("仅接受一个本地 IPA 文件。", isError: true)
            return
        }
        self.isBusy = true
        self.setStatus("正在检查 IPA 的应用标识与版本…")
        ALTDeviceManager.shared.inspectManagedIPA(at: url) { [weak self] result in
            guard let self = self else { return }
            switch result
            {
            case .failure(let error):
                self.isBusy = false
                self.setStatus("IPA 检查失败，未更新任何应用：" + self.errorMessage(error), isError: true)
            case .success(let ipa):
                let matches = self.applications.filter { self.originalIdentifiers(for: $0).contains(ipa.bundleIdentifier) }
                let target: ManagedApplication
                if matches.count == 1
                {
                    target = matches[0]
                }
                else if matches.count > 1, self.selectedApplications.count == 1,
                        let selected = self.selectedApplications.first,
                        matches.contains(where: { $0.bundleIdentifier == selected.bundleIdentifier })
                {
                    target = selected
                }
                else
                {
                    self.isBusy = false
                    let message = matches.isEmpty
                        ? "IPA「\(ipa.name)」的标识（\(ipa.bundleIdentifier)）与此设备的已安装应用不匹配，已拒绝更新。"
                        : "此 IPA 匹配多个已安装应用。请在列表中只选中一个目标，再重新选择或拖入此 IPA。"
                    self.setStatus(message, isError: true)
                    return
                }
                if let row = self.applications.firstIndex(where: { $0.bundleIdentifier == target.bundleIdentifier })
                {
                    self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                let details = "设备：\(device.name)\n目标：\(target.name)（\(target.bundleIdentifier)）\n版本：\(target.version) → \(ipa.version)\nIPA：\(ipa.name)（\(ipa.bundleIdentifier)）"
                self.setStatus("准备更新「\(target.name)」：\(target.version) → \(ipa.version)。")
                self.requestCredentials(title: "更新「\(target.name)」", details: details, submitTitle: "确认更新") { [weak self] appleID, password in
                    guard let self = self else { return }
                    self.setStatus("正在更新「\(target.name)」，请保持设备连接…")
                    ALTDeviceManager.shared.updateManagedApplication(target.bundleIdentifier, withIPAAt: ipa.url, on: device, appleID: appleID, password: password) { [weak self] result in
                        guard let self = self else { return }
                        switch result
                        {
                        case .success(let application):
                            self.reloadApplications(finalStatus: Status(message: "「\(application.name)」已更新为 \(application.version)。", isError: false))
                        case .failure(let error):
                            self.reloadApplications(finalStatus: Status(message: "更新失败：" + self.errorMessage(error), isError: true))
                        }
                    }
                }
            }
        }
    }

    private func originalIdentifiers(for application: ManagedApplication) -> Set<String>
    {
        let identifier = application.bundleIdentifier
        var identifiers: Set<String> = [identifier]
        let components = identifier.split(separator: ".").map(String.init)
        func isTeamIdentifier(_ value: String) -> Bool
        {
            if let team = application.teamIdentifier { return value == team }
            return value.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
        }
        if components.count > 2, components[0] == "com", isTeamIdentifier(components[1])
        {
            identifiers.insert(components.dropFirst(2).joined(separator: "."))
        }
        if components.count > 1, let suffix = components.last, isTeamIdentifier(suffix)
        {
            identifiers.insert(components.dropLast().joined(separator: "."))
        }
        return identifiers
    }

    private func requestCredentials(title: String, details: String, submitTitle: String, operation: @escaping (String, String) -> Void)
    {
        guard let window = self.window else { self.isBusy = false; return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = details + "\n\n请输入同一签名账户的 Apple ID 和密码。信息仅用于本次操作，完成后清空。"
        alert.addButton(withTitle: submitTitle)
        alert.addButton(withTitle: "取消")
        let appleIDField = NSTextField()
        appleIDField.placeholderString = "Apple ID"
        appleIDField.delegate = self
        let passwordField = NSSecureTextField()
        passwordField.placeholderString = "密码"
        passwordField.delegate = self
        let fields = NSStackView(views: [appleIDField, passwordField])
        fields.orientation = .vertical
        fields.spacing = 10
        fields.frame = NSRect(x: 0, y: 0, width: 380, height: 60)
        for field in [appleIDField, passwordField]
        {
            field.widthAnchor.constraint(equalToConstant: 380).isActive = true
        }
        alert.accessoryView = fields
        alert.window.initialFirstResponder = appleIDField
        appleIDField.nextKeyView = passwordField
        self.credentialAppleIDField = appleIDField
        self.credentialPasswordField = passwordField
        self.credentialSubmitButton = alert.buttons.first
        self.credentialSubmitButton?.isEnabled = false
        alert.beginSheetModal(for: window) { [weak self] response in
            let appleID = appleIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let password = passwordField.stringValue
            appleIDField.stringValue = ""
            passwordField.stringValue = ""
            guard let self = self else { return }
            self.credentialAppleIDField = nil
            self.credentialPasswordField = nil
            self.credentialSubmitButton = nil
            guard response == .alertFirstButtonReturn, !appleID.isEmpty, !password.isEmpty else
            {
                self.isBusy = false
                self.setStatus("已取消操作。")
                return
            }
            operation(appleID, password)
        }
    }

    func controlTextDidChange(_ notification: Notification)
    {
        let hasAppleID = !(self.credentialAppleIDField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasPassword = !(self.credentialPasswordField?.stringValue.isEmpty ?? true)
        self.credentialSubmitButton?.isEnabled = hasAppleID && hasPassword
    }

    func numberOfRows(in tableView: NSTableView) -> Int { self.applications.count }

    func tableViewSelectionDidChange(_ notification: Notification) { self.updateControls() }

    func selectionShouldChange(in tableView: NSTableView) -> Bool { !self.isBusy }

    private func updateCountdowns()
    {
        guard self.window?.isVisible == true, !self.applications.isEmpty,
              let column = self.tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "expiration" }) else { return }
        self.tableView.reloadData(forRowIndexes: IndexSet(integersIn: self.applications.indices),
                                  columnIndexes: IndexSet(integer: column))
    }

    static func remainingTimeDescription(for expiration: Date?, relativeTo now: Date = Date(), calendar: Calendar = .current) -> (text: String, isExpired: Bool)
    {
        guard let expiration = expiration else { return ("剩余时间未知", false) }
        let seconds = expiration.timeIntervalSince(now)
        guard seconds > 0 else { return ("已过期", true) }
        // Match My Apps: remaining days count local calendar boundaries rather
        // than rounding elapsed 24-hour intervals up to another day.
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expiration)).day ?? 0
        if days > 0
        {
            return ("剩余 \(days) 天", false)
        }
        if seconds >= 3_600
        {
            return ("剩余约 \(Int(ceil(seconds / 3_600))) 小时（不足 1 天）", false)
        }
        return ("不足 1 小时", false)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
    {
        guard self.applications.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let application = self.applications[row]
        if identifier == "application"
        {
            let name = NSTextField(labelWithString: application.name)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.lineBreakMode = .byTruncatingTail
            let bundleID = NSTextField(labelWithString: application.bundleIdentifier)
            bundleID.font = .systemFont(ofSize: 11)
            bundleID.textColor = .secondaryLabelColor
            bundleID.lineBreakMode = .byTruncatingMiddle
            bundleID.toolTip = application.bundleIdentifier
            let stack = NSStackView(views: [name, bundleID])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
            name.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -16).isActive = true
            bundleID.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -16).isActive = true
            return stack
        }
        if identifier == "version" { return NSTextField(labelWithString: application.version) }
        let remainingTime = Self.remainingTimeDescription(for: application.expirationDate)
        let expirationLabel = NSTextField(labelWithString: application.expirationDate.map(self.dateFormatter.string(from:)) ?? "未读到描述文件")
        let remainingLabel = NSTextField(labelWithString: remainingTime.text)
        remainingLabel.font = .systemFont(ofSize: 11)
        expirationLabel.textColor = remainingTime.isExpired ? .systemRed : (application.expirationDate == nil ? .secondaryLabelColor : .labelColor)
        remainingLabel.textColor = remainingTime.isExpired ? .systemRed : .secondaryLabelColor
        let stack = NSStackView(views: [expirationLabel, remainingLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 0, bottom: 5, right: 8)
        for label in [expirationLabel, remainingLabel]
        {
            label.lineBreakMode = .byTruncatingTail
            label.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -8).isActive = true
        }
        stack.toolTip = "手机描述文件实际到期时间（本地时间）：\(expirationLabel.stringValue)\n\(remainingTime.text)"
        return stack
    }
}

private final class ManagedIPADropView: NSView
{
    var onDrop: ((URL) -> Void)?
    var onRejection: ((String) -> Void)?
    var isEnabled = false
    {
        didSet { self.alphaValue = self.isEnabled ? 1 : 0.5 }
    }

    override init(frame frameRect: NSRect)
    {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.layer?.borderWidth = 1
        self.layer?.borderColor = NSColor.separatorColor.cgColor
        let title = NSTextField(labelWithString: "拖入一个 IPA，更新已安装的应用")
        title.font = .systemFont(ofSize: 14, weight: .medium)
        let detail = NSTextField(labelWithString: "先匹配应用标识并显示目标与版本；不接受其他应用或多个 IPA。")
        detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.spacing = 8
        labels.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(labels)
        NSLayoutConstraint.activate([
            labels.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            labels.centerYAnchor.constraint(equalTo: self.centerYAnchor)
        ])
        self.registerForDraggedTypes([.fileURL])
        self.setAccessibilityLabel("拖入一个 IPA 更新已安装的应用")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func fileURL(from sender: NSDraggingInfo) -> URL?
    {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == 1, let url = urls.first, url.pathExtension.lowercased() == "ipa",
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation
    {
        guard self.isEnabled else { return [] }
        guard self.fileURL(from: sender) != nil else
        {
            self.onRejection?("一次只能拖入一个 IPA 文件；文件夹、其他文件或多个 IPA 均不接受。")
            return []
        }
        self.layer?.borderColor = NSColor.controlAccentColor.cgColor
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?)
    {
        self.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool
    {
        self.layer?.borderColor = NSColor.separatorColor.cgColor
        guard self.isEnabled, let url = self.fileURL(from: sender) else { return false }
        self.onDrop?(url)
        return true
    }
}
