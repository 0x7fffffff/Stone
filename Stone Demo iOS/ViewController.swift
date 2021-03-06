//
//  ViewController.swift
//  Stone Demo iOS
//
//  Created by Michael MacCallum on 7/27/16.
//
//

import UIKit
import Stone
import Unbox

struct UserDevice: Unboxable, Hashable {
	let onlineAt: Date
	let ref: String
	let deviceId: UUID

	var hashValue: Int {
		return deviceId.hashValue
	}

	init(unboxer: Unboxer) throws {
		ref = try unboxer.unbox(key: "phx_ref")

		let timestamp: TimeInterval = try unboxer.unbox(key: "online_at")
		onlineAt = Date(timeIntervalSince1970: timestamp)

		let uuidString: String = try unboxer.unbox(key: "device_token")
		deviceId = UUID(uuidString: uuidString)!
	}
}

func ==(lhs: UserDevice, rhs: UserDevice) -> Bool {
	return lhs.deviceId == rhs.deviceId
}

struct ChatMessage: Unboxable {
	let sender: String
	let body: String

	init(unboxer: Unboxer) throws {
		sender = try unboxer.unbox(key: "user_id")
		body = try unboxer.unbox(key: "body")
	}
}

class ViewController: UIViewController {
	fileprivate var messages = [ChatMessage]()

	@IBOutlet fileprivate weak var tableView: UITableView!
	@IBOutlet fileprivate weak var textField: UITextField!
	@IBOutlet fileprivate weak var sendButton: UIButton!
	@IBOutlet fileprivate weak var bottomSpacingPin: NSLayoutConstraint!

	fileprivate var confirmAction: UIAlertAction?
	fileprivate var userId: String!
	fileprivate var activeUsers = [String: Set<UserDevice>]() {
		didSet {
			navigationItem.prompt = "\(activeUsers.count) user(s) connected"
		}
	}

	fileprivate lazy var socket: Socket = {
		let url = URL(
			string: "http://192.168.0.28:4000/socket/websocket"
		)!

		return Socket(
			url: url,
			heartbeatInterval: 15.0,
			reconnectInterval: 15.0
		)!
	}()

	override func viewDidLoad() {
		super.viewDidLoad()
		chatConfig()
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		let alertController = UIAlertController(
			title: "Welcome to Stone Chat",
			message: "Please choose a user ID",
			preferredStyle: .alert
		)

		alertController.addTextField { [unowned self] textField in
			textField.addTarget(self, action: #selector(ViewController.textFieldEditingChanged(_:)), for: .editingChanged)
		}

		confirmAction = UIAlertAction(
			title: "Confirm",
			style: .default) { [unowned alertController] action in
				self.confirmAction = nil
				self.userId = alertController.textFields!.first!.text!
				self.socketConfig()
		}

		confirmAction!.isEnabled = false
		alertController.addAction(confirmAction!)

		present(alertController, animated: true, completion: nil)
	}

	fileprivate func socketConfig() {
		let channel = Channel(topic: "chat:lobby")
		channel.shouldTrackPresence = true

		channel.onEvent(Event.custom("new:msg")) { [unowned self] result in
			do {
				let payload = try result.value().payload
				self.messages.append(try unbox(dictionary: payload))
				self.tableView.reloadData()
			} catch {
				print(error)
			}
		}

		channel.onPresenceState { [unowned self] result in
			do {
				let presences = try result.value()
				self.activeUsers.removeAll()

				for presence in presences {
					do {
						let metas: [UserDevice] = try unbox(dictionaries: presence.metas["metas"] as! [[String: AnyObject]])
						self.activeUsers[presence.name] = Set(metas)
					} catch {
						print(error)
					}
				}
			} catch {
				print("presence state failed")
			}
		}

		channel.onPresenceDiff { [unowned self] result in
			do {
				let diff = try result.value()

				for presence in diff.joins {
					do {
						let metas: [UserDevice] = try unbox(dictionaries: presence.metas["metas"] as! [[String: AnyObject]])

						if let existingPresences = self.activeUsers[presence.name] {
							self.activeUsers[presence.name] = Set(metas).union(existingPresences)
						} else {
							self.activeUsers[presence.name] = Set(metas)
						}
					} catch {
						print(error)
					}
				}
				
				for presence in diff.leaves {
					do {
						let metas: [UserDevice] = try unbox(dictionaries: presence.metas["metas"] as! [[String: AnyObject]])

						if let existingPresences = self.activeUsers[presence.name] {
							self.activeUsers[presence.name] = existingPresences.subtracting(Set(metas))
						}
					} catch {
						print(error)
					}
				}
			} catch {
				print("presence diff failed")
			}
		}

		socket.addChannel(channel)

		socket.shouldReconnectOnError = true
		socket.shouldAutoJoinChannels = true

		socket.onOpen = {
			print("socket open")
		}

		socket.onMessage = { message in
			print("Socket message: \(message)")
		}

		socket.onHeartbeat = { result in
			print("Heartbeat")
		}

		socket.onError = { (error: NSError) in
			print("socket received error: \(error)")
		}

		socket.onClose = { (code: Int, reason: String, clean: Bool) in
			print("socket closed - code: \(code), reason: \(reason), clean: \(clean)")
		}

		socket.connect(
			[
				"user_id": userId,
				"device_token": UIDevice.current.identifierForVendor!.uuidString
			]
		)
	}

	fileprivate func chatConfig() {
		tableView.estimatedRowHeight = 60.0
		tableView.rowHeight = UITableViewAutomaticDimension
		tableView.tableFooterView = UIView()

		NotificationCenter.default.addObserver(forName: NSNotification.Name.UIKeyboardWillChangeFrame, object: nil, queue: .main) { [unowned self] notification in
			guard self.textField.isFirstResponder else {
				return
			}

			guard let userInfo = (notification as NSNotification).userInfo,
				let animationCurve = userInfo[UIKeyboardAnimationCurveUserInfoKey] as? UInt,
				let animationDuration = userInfo[UIKeyboardAnimationDurationUserInfoKey] as? TimeInterval,
				let keyboardFrame = (userInfo[UIKeyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
					return
			}

			let inset = keyboardFrame.origin.y == self.view.bounds.height ? 0.0 : keyboardFrame.height
			self.bottomSpacingPin.constant = inset

			UIView.animate(
				withDuration: animationDuration,
				delay: 0.0,
				options: UIViewAnimationOptions.beginFromCurrentState.union(UIViewAnimationOptions(rawValue: animationCurve)),
				animations: {
					self.tableView.contentInset.bottom = inset
					self.view.layoutIfNeeded()
				},
				completion: nil
			)
		}
	}

	override func didReceiveMemoryWarning() {
		super.didReceiveMemoryWarning()
		// Dispose of any resources that can be recreated.
	}

	@IBAction fileprivate func sendMessage(_ barButton: UIBarButtonItem) {
		guard let channel = socket.channelForTopic("chat:lobby"),
			let text = textField.text else {
			return
		}

		sendButton.isEnabled = false

//		let message = Stone.Message(
//			topic: channel.topic,
//			event: Event.custom("new:msg"),
//			payload: [
//				"body": text
//			]
//		)

		
		let message = Message(
			topic: channel.topic,
			event: Event.custom("new:msg"),
			payload: ["": text as AnyObject],
			ref: nil
		)

		channel.sendMessage(message) { result in
			do {
				_ = try result.value()
				self.textField.text = ""
			} catch {
				print(error)
				self.sendButton.isEnabled = true
			}
		}
	}

	@IBAction dynamic fileprivate func textFieldEditingChanged(_ sender: UITextField) {
		let shouldEnable = sender.text?.characters.count ?? 0 != 0

		if sender === textField {
			sendButton.isEnabled = shouldEnable
		} else {
			confirmAction?.isEnabled = shouldEnable
		}
	}

	override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
		guard let _ = segue.destination as? UserListTableViewController , segue.identifier == "" else {
			super.prepare(for: segue, sender: sender)
			return
		}


	}
}

extension ViewController: UITableViewDataSource {
	func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		return messages.count
	}

	func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		let cell = tableView.dequeueReusableCell(withIdentifier: "cell_id", for: indexPath) as! ChatMessageTableViewCell

		cell.chatMessage = messages[(indexPath as NSIndexPath).row]

		if (indexPath as NSIndexPath).row % 2 == 0 {
			cell.backgroundColor = UIColor.white
		} else {
			cell.backgroundColor = UIColor(white: 0.95, alpha: 1.0)
		}

		return cell
	}
}

extension ViewController: UITableViewDelegate {
	func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {

	}
}
