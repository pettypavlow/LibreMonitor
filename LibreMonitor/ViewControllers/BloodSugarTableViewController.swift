//
//  TableViewController.swift
//
//  Created by Uwe Petersen on 01.02.16.
//  Copyright © 2016 Uwe Petersen. All rights reserved.
//

import Foundation

import UIKit
import CoreBluetooth
import CoreData
import UserNotifications
import os.log


final class BloodSugarTableViewController: UITableViewController, SimbleeManagerDelegate, MiaoMiaoManagerDelegate {
    
    // MARK: - Properties
    
    enum Device {
        case miaoMaio
        case simblee
    }
    
    let device: Device = .miaoMaio
//    let device: Device = .simblee
    var firmware = String()
    var hardware = String()

    static let bt_log = OSLog(subsystem: "com.LibreMonitor", category: "BloodSugarTableViewController")
    
    var persistentContainer: NSPersistentContainer?
    var miaoMiaoManager = MiaoMiaoManager()
    var simbleeManager = SimbleeManager()
    var uploader: NightscoutUploader?
    private(set) var nightscoutEntries = [NightscoutEntry]()

    
    var sensorData: SensorData?
    var trendMeasurements: [Measurement]?
    var historyMeasurements: [Measurement]?
    var batteryVoltage = 0.0
    var oopCurrentValue: OOPCurrentValue?
    
    var bloodGlucoseOffset: Double!
    var bloodGlucoseSlope: Double!
    var sensor: FreestyleLibreSensor?

    var deviceID = "-"
    var temperatureString = "_"
    
    var timeInMinutesSinceStartOfSensor = 0
    var timeOfLastScan = Date()
    var transmissionDuration = TimeInterval()
    var nfcReadingDuration = TimeInterval() // receiving system information data -> receiving battery voltage
    var bluetoothTransmissionDuration = TimeInterval()  // receiving battery voltage -> receiving IDN-Data
    var nfcReadingStart = Date()
    var bluetoothTransmissionStart = Date()
    var timeOfTransmissionStart = Date()
    var timer = Timer()
    
    
    var dateFormatter = DateFormatter()
    var timeFormatter = DateFormatter()
    
    
    /// Enum for the sections of this table view
    fileprivate enum Section: Int {
        case connectionData, generalData, graph, trendData, historyData
        /// Count of enum cases (has to be adjusted to this/each very enum)
        /// Source: http://stackoverflow.com/questions/27094878/how-do-i-get-the-count-of-a-swift-enum
        static let count: Int = {
            var max: Int = 0
            while let _ = Section(rawValue: max) { max += 1 }
            return max
        }()
    }
    
    
    @IBAction func doRefresh(_ sender: UIRefreshControl) {
        if let writeCharacteristic = miaoMiaoManager.writeCharacteristic {
            miaoMiaoManager.peripheral?.writeValue(Data.init(bytes: [0xD3, 0x01]), for: writeCharacteristic, type: .withResponse)
            miaoMiaoManager.rxBuffer = Data()
            miaoMiaoManager.peripheral?.writeValue(Data.init(bytes: [0xF0]), for: writeCharacteristic, type: .withResponse)
        }
        sender.endRefreshing()
        tableView.reloadData()
    }
    
    // MARK: - View Controller life ciycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        switch device {
        case .simblee:
            simbleeManager.delegate = self
        case .miaoMaio:
            miaoMiaoManager.delegate = self
        }
        self.navigationItem.title = "LibreMonitor"
        if let site = UserDefaults.standard.string(forKey: "nightscoutSite"), let siteURL = URL.init(string: site), let apiSecret = UserDefaults.standard.string(forKey: "nightscoutAPISecret") {
            uploader = NightscoutUploader(siteURL: siteURL, APISecret: apiSecret)
        }
        
        let connectButtonTitle = connectButtonTitleForState(simbleeManager.state)
        let conncectButton = UIBarButtonItem(title: connectButtonTitle, style: .plain, target: self, action: #selector(BloodSugarTableViewController.didTapConnectButton))
        self.navigationItem.rightBarButtonItem = conncectButton
        
        bloodGlucoseOffset = UserDefaults.standard.double(forKey: "bloodGlucoseOffset")
        bloodGlucoseSlope = UserDefaults.standard.double(forKey: "bloodGlucoseSlope")
        if bloodGlucoseSlope <= 0.00001 {
            bloodGlucoseSlope = 1.0
            UserDefaults.standard.set(bloodGlucoseSlope, forKey: "bloodGlucoseSlope")
        }
        
        
        dateFormatter.dateFormat = "yyyy-MM-dd"
        timeFormatter.dateFormat = "HH:mm:ss"
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        bloodGlucoseOffset = UserDefaults.standard.double(forKey: "bloodGlucoseOffset")
        bloodGlucoseSlope = UserDefaults.standard.double(forKey: "bloodGlucoseSlope")
        
        // Notification for updating table view after application did become active again
        NotificationCenter.default.addObserver(self, selector: #selector(BloodSugarTableViewController.updateTableView), name: UIApplication.didBecomeActiveNotification, object: nil)
        // Notification for updating table view after having changed the offset and/of slope
        NotificationCenter.default.addObserver(self, selector: #selector(BloodSugarTableViewController.updateTableView), name: NSNotification.Name(rawValue: "updateBloodSugarTableViewController"), object: nil)
    
        // Timer to update diplayed time
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(5), repeats: true, block: {timer in
            self.updateTableView()
        })
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        super.viewWillDisappear(true)
        timer.invalidate()
    }
    
    
    @objc func didTapConnectButton() {
        switch device {
        case .simblee:
            
            return
            
//            switch (simbleeManager.state) {
//            case .Unassigned:
//                simbleeManager.scanForSimblee()
//            case .Scanning:
//                simbleeManager.centralManager.stopScan()
//                simbleeManager.state = .Disconnected
//            case .Connected, .Connecting, .Notifying:
//                simbleeManager.disconnectManually()
//            case .Disconnected, .DisconnectingDueToButtonPress:
//                simbleeManager.connect()
//            }
        case .miaoMaio:
            switch (miaoMiaoManager.state) {
            case .Unassigned:
                miaoMiaoManager.scanForMiaoMiao()
            case .Scanning:
                miaoMiaoManager.centralManager.stopScan()
                miaoMiaoManager.state = .Disconnected
            case .Connected, .Connecting, .Notifying:
                miaoMiaoManager.disconnectManually()
            case .Disconnected, .DisconnectingDueToButtonPress:
                miaoMiaoManager.connect()
            }
        }
        
    }
    
    
    @objc func updateTableView() {
        os_log("Update table view", log: BloodSugarTableViewController.bt_log, type: .default)
        self.tableView.reloadData()
    }
    
    override func didReceiveMemoryWarning() {
        os_log("Did receive memory warning", log: BloodSugarTableViewController.bt_log, type: .default)
        NotificationManager.scheduleApplicationDidReceiveMemoryWarningdNotification()
    }

    // MARK: - Table View
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.count
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .connectionData: return 3
        case .generalData: return 8
        case .graph: return 1
        case .trendData: return 16
        case .historyData: return 32
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        
        if (indexPath as NSIndexPath).section == 2 {
            
            // Draw graph
            let cell = tableView.dequeueReusableCell(withIdentifier: "BloodSugarGraphTableViewCell", for: indexPath)
            guard let theCell = cell as? BloodSugarGraphViewTableViewCell else {return cell}

            if let trendMeasurements = trendMeasurements, let historyMeasurements = historyMeasurements {
                theCell.lineChartView.trendMeasurements = trendMeasurements
                theCell.lineChartView.historyMeasurements = historyMeasurements
                theCell.lineChartView.oopCurrentValue = oopCurrentValue
                theCell.lineChartView.setGlucoseCharts(trendMeasurements: trendMeasurements, historyMeasurements: historyMeasurements, oopCurrentValue: oopCurrentValue)
                theCell.setNeedsDisplay()
                theCell.lineChartView.setNeedsDisplay()
            }
            return theCell
        } else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            self.configureCell(cell, atIndexPath: indexPath)
            return cell
        }
    }
    
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        // Return false if you do not want the specified item to be editable.
        return true
    }

    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Connection"
        case 1: return "General data"
        case 2:
            let seconds = (NSDate() as NSDate).timeIntervalSince(timeOfLastScan).truncatingRemainder(dividingBy: 60.0)
            let minutes = (Date().timeIntervalSince(timeOfLastScan) - seconds) / 60.0
            return String(format: "Graph from %2.0f:%02.0f minutes ago", arguments: [minutes, seconds])
        case 3: return "Last 15 minutes"
        case 4: return "Last eight hours"
        case 5: return "Neue Letzte 15 Minuten"
        case 6: return "Neue Letzte 8 Stunden"
        default: return nil
        }
    }
    
    
    func configureCell(_ cell: UITableViewCell, atIndexPath indexPath: IndexPath) {
        cell.backgroundColor = UIColor.white
        cell.detailTextLabel?.textColor = UIColor.black
        cell.accessoryType = .none
        
        switch Section(rawValue: (indexPath as NSIndexPath).section)! {
        case .connectionData:
            switch (indexPath as NSIndexPath).row {
            case 0:
                switch device {
                case .miaoMaio:
                    cell.textLabel?.text = "Miaomiao status"
                    cell.detailTextLabel?.text = miaoMiaoManager.state.rawValue
                    cell.backgroundColor = colorForConnectionMiaoMiaoState()
                case .simblee:
                    cell.textLabel?.text = "Simblee status"
                    cell.detailTextLabel?.text = simbleeManager.state.rawValue
                    cell.backgroundColor = colorForConnectionState()
                }
            case 1:
                cell.textLabel?.text = "Last scan:"
                if let sennsorData = sensorData {
                    cell.detailTextLabel?.text = String(format: "\(dateFormatter.string(from: sennsorData.date as Date)), at \(timeFormatter.string(from: sennsorData.date as Date)), in %.2f s (%.2f+%.2f NFC/Bluetooth)", arguments: [transmissionDuration, nfcReadingDuration, bluetoothTransmissionDuration])
                    
                    if Date().timeIntervalSince(sennsorData.date as Date) > 450.0 {
                        cell.backgroundColor = UIColor.red
                    }
                }
            case 2:
                cell.textLabel?.text = "Offset / Slope:"
                cell.detailTextLabel?.text = String(format: "%.0f mg/dl, %.4f", arguments: [bloodGlucoseOffset, bloodGlucoseSlope])
                cell.accessoryType = .disclosureIndicator
            default: break
            }
        case .generalData:
            switch (indexPath as NSIndexPath).row {
            case 0:
                switch device {
                case .miaoMaio:
                    cell.textLabel?.text = "Firmware"
                    cell.detailTextLabel?.text = firmware
                case .simblee:
                    cell.textLabel?.text = "BM019 ID"
                    cell.detailTextLabel?.text = deviceID
                }
            case 1:
                switch device {
                case .miaoMaio:
                    var crcString = String()
                    var color = UIColor()
                    if let sensorData = sensorData {
                        crcString.append(", crcs: \(sensorData.hasValidHeaderCRC), \(sensorData.hasValidBodyCRC), \(sensorData.hasValidFooterCRC)")
                        color = colorForSensorState( (sensorData.hasValidHeaderCRC && sensorData.hasValidBodyCRC )) // only header and body crc
                    } else {
                        crcString = ", nil"
                        color = UIColor.lightGray
                    }
                    if let sensor = sensor {
                        cell.textLabel?.text = "Sensor SN"
                        cell.detailTextLabel?.text =  sensor.serialNumber + crcString + " " + hardware // + " (" + sensor.prettyUid  + ")"
                    } else {
                        cell.textLabel?.text = "Hardware"
                        cell.detailTextLabel?.text = hardware
                    }
                    cell.backgroundColor = color
                case .simblee:
                    var crcString = String()
                    var color = UIColor()
                    if let sensorData = sensorData {
                        crcString.append(", crcs: \(sensorData.hasValidHeaderCRC), \(sensorData.hasValidBodyCRC), \(sensorData.hasValidFooterCRC)")
                        color = colorForSensorState( (sensorData.hasValidHeaderCRC && sensorData.hasValidBodyCRC && sensorData.hasValidFooterCRC) )
                    } else {
                        crcString = ", nil"
                        color = UIColor.lightGray
                    }
                    cell.textLabel?.text = "Sensor SN"
                    if let sensor = sensor {
                        cell.detailTextLabel?.text =  sensor.serialNumber + crcString // + " (" + sensor.prettyUid  + ")"
                    } else {
                        cell.detailTextLabel?.text = ""
                    }
                    cell.backgroundColor = color
                }
                
                
            case 2:
                switch device {
                case .miaoMaio:
                    cell.textLabel?.text = "Battery"
                    cell.detailTextLabel?.text = String(format: "%3.0f %%", arguments: [batteryVoltage])
                    if batteryVoltage < 10.0 {
                        cell.backgroundColor = UIColor.orange
                    }                case .simblee:
                    cell.textLabel?.text = "Environment"
                    cell.detailTextLabel?.text = String(format: "%3.1f V", arguments: [batteryVoltage]) + ", " + temperatureString
                    if batteryVoltage < 3.5 {
                        cell.backgroundColor = UIColor.orange
                    }                }

            case 3:
                cell.textLabel?.text = "Blocks"
                if let sennsorData = sensorData {
                    cell.detailTextLabel?.text = "Trend: \(sennsorData.nextTrendBlock), history: \(sennsorData.nextHistoryBlock), minutes: \(sennsorData.minutesSinceStart)"
                }
            case 4:
                cell.textLabel?.text = "Glucose"
                
                if let trendMeasurements = trendMeasurements {
                    let currentGlucose = trendMeasurements[0].glucose
                    let longDelta = currentGlucose - trendMeasurements[15].glucose
                    let shortDelta = (currentGlucose - trendMeasurements[8].glucose) * 2.0 * 16.0/15.0
                    let longPrediction = currentGlucose + longDelta
                    let shortPrediction = currentGlucose + shortDelta
                    cell.detailTextLabel?.text = String(format: "%0.0f, Delta: %0.0f (%0.0f), Prognosis: %0.0f (%0.0f)", arguments: [currentGlucose, longDelta, shortDelta, longPrediction, shortPrediction])
                    if longPrediction < 70.0 || shortPrediction < 70.0 || longPrediction > 180.0 || shortPrediction > 180.0 || (abs(longDelta) > 30.0 && abs(shortDelta) > 30.0) {
                        cell.detailTextLabel?.textColor = UIColor.red
                    } else {
                        cell.detailTextLabel?.textColor = UIColor.black
                    }
                }

            case 5:
                cell.textLabel?.text = "Sensor started"
                if let sennsorData = sensorData {
                    let minutes = sennsorData.minutesSinceStart
                    let days = Int( Double(minutes) / 24.0 / 60.0 )
                    let hours = Int( Double(minutes) / 60.0 ) - days*24
                    let minutesRest = minutes - days*24*60 - hours*60
                    cell.detailTextLabel?.text = String(format: "%d day(s), %d hour(s) and %d minute(s) ago", arguments: [days, hours, minutesRest])
                }
            case 6:
                cell.textLabel?.text = "Sensor status"
                if let sennsorData = sensorData {
                    cell.detailTextLabel?.text = sennsorData.state.description
                } else {
                    cell.detailTextLabel?.text = "nil"
                }
            case 7:
                cell.textLabel?.text = "OOP Glucose"
                if let sensorData = sensorData, let oopCurrentValue = oopCurrentValue {
                    cell.detailTextLabel?.text = "\(oopCurrentValue.currentBg) mg/dl, time: \(oopCurrentValue.currentTime), trend: \(oopCurrentValue.currentTrend) at \(timeFormatter.string(from: sensorData.date))"
                } else {
                    cell.detailTextLabel?.text = "-"
                }
                
            default:
                cell.textLabel?.text = "Something ..."
                cell.detailTextLabel?.text = "... didn't work"
            }
        case .graph:
            break
            
        case .trendData:
            let index = (indexPath as NSIndexPath).row
            if let measurements = trendMeasurements {
                let timeAsString = timeFormatter.string(from: measurements[index].date as Date)
                let dateAsString = dateFormatter.string(from: measurements[index].date as Date)
                let rawString = String(format: "%0d, %0d", measurements[index].rawGlucose, measurements[index].rawTemperature)

                cell.textLabel?.text = String(format: "%0.1f mg/dl", measurements[index].glucose)
                cell.detailTextLabel?.text = "\(timeAsString), \(rawString), \(measurements[index].byteString), \(dateAsString), \(index)"
            }

        case .historyData:
            let index = (indexPath as NSIndexPath).row
            if let measurements = historyMeasurements {
                let timeAsString = timeFormatter.string(from: measurements[index].date as Date)
                let dateAsString = dateFormatter.string(from: measurements[index].date as Date)
                var rawString = String(format: "%0d, %0d", measurements[index].rawGlucose, measurements[index].rawTemperature)
                if let oopCurrentValue = self.oopCurrentValue {
                    let aString = String(format: ", oop: %0d, %0d, %0d", Int(round(oopCurrentValue.historyValues[31-index].bg)), oopCurrentValue.historyValues[31-index].time, oopCurrentValue.historyValues[31-index].quality)
                    rawString.append(aString)
                }

                cell.textLabel?.text = String(format: "%0.1f mg/dl", measurements[index].glucose)
                cell.detailTextLabel?.text = "\(timeAsString), \(rawString), \(measurements[index].byteString), \(dateAsString), \(index)"
            }
        }
    }
    
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if (indexPath as NSIndexPath).section == 2 {
            return CGFloat(300)
        }
        return CGFloat(20)
    }
    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return CGFloat(20)
    }
    
    
    // MARK: - Navigation
    
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch Section(rawValue: indexPath.section)! {
        case .connectionData:
            if indexPath.row == 0 {
                didTapConnectButton()
            } else if indexPath.row == 2 {
                performSegue(withIdentifier: "ChangeBloodGlucoseAdjustments", sender: self) // ChangeBloodGlucoseAdjustments
            }
        case .trendData, .historyData:
            performSegue(withIdentifier: "showGlucoseCDTVC", sender: self)
        default:
            break
        }
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "ChangeBloodGlucoseAdjustments" {
            print("Segue ChangeBloodGlucoseAdjustments")
        } else if segue.identifier == "showGlucoseCDTVC" {
            if let vc = segue.destination as? GlucoseCDTVC {
                vc.persistentContainer = persistentContainer
            }
        }
    }
    
    
    // MARK: MiaoMiaoManagerDelegate

    func miaoMiaoManagerPeripheralStateChanged(_ state: MiaoMiaoManagerState) {
        os_log("MiaMiao manager peripheral state changed to %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: state.rawValue))
        
        self.navigationItem.rightBarButtonItem?.title? = connectButtonTitleForMiaoMiaoState(state)
        
        switch state {
        case .Unassigned, .Connecting, .Connected, .Scanning, .DisconnectingDueToButtonPress, .Disconnected:
            NotificationManager.applicationIconBadgeNumber(value: 0) // Data not accurate any more -> remove badge icon
            NotificationManager.scheduleBluetoothDisconnectedNotification(wait: 450)
        case .Notifying:
            NotificationManager.removePendingBluetoothDisconnectedNotification()
        }
        tableView.reloadData()
    }
    
    func miaoMiaoManagerReceivedMessage(_ messageIdentifier: UInt16, txFlags: UInt8, payloadData: Data) {
        
        NotificationManager.scheduleApplicationTerminatedNotification(wait: 500)
        
        os_log("Received message with txFlags %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: txFlags))
        
        firmware = String(describing: Data(bytes: [txFlags]).hexEncodedString()) + " " + String(describing: payloadData.prefix(40).hexEncodedString())
        hardware = String(describing: payloadData.count) + " " + String(describing: payloadData.suffix(30).hexEncodedString())
        
        if txFlags == 0x28 || txFlags == 0x29 {

            batteryVoltage = Double([UInt8](payloadData.subdata(in: 13..<14)).first ?? 0)
            os_log("Battery data is %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: "\(batteryVoltage) %"))
            if batteryVoltage < 10 {
                NotificationManager.setLowBatteryNotification(voltage: Double(batteryVoltage))
            }
            
            sensor = FreestyleLibreSensor(withUID: Data(payloadData.subdata(in: 5..<13)))
            sensorData = SensorData(bytes: [UInt8](payloadData.subdata(in: 18..<362)), date: Date())
            
//            os_log("All bytes data is %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: sensorData.debugDescription))
            os_log("FRAM indices: %{public}@, %{public}@ and counter: %{public}@, date: %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: sensorData?.nextTrendBlock), String(describing: sensorData?.nextHistoryBlock), String(describing: sensorData?.minutesSinceStart), String(describing: sensorData?.date))

            if let sensorData = sensorData {
                
                
                // if crc (header or body) is wrong. Request data again.
                if !(sensorData.hasValidHeaderCRC && sensorData.hasValidBodyCRC) {
                    let crcString = String("crcs: \(sensorData.hasValidHeaderCRC), \(sensorData.hasValidBodyCRC), \(sensorData.hasValidFooterCRC)")

                    os_log("At least one CRC is wrong %{public}@. Request data again in some seconds", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: crcString))
                    Timer.scheduledTimer(withTimeInterval: 30, repeats: false, block: {_ in
                        self.miaoMiaoManager.requestData()
                    })
                    
                } else {
                    NotificationManager.scheduleDataTransferInterruptedNotification(wait: 400)

                    if sensorData.hasValidFooterCRC {
                        getOOPGlucose(fram: sensorData.bytes)
                    }
                    
                    timeOfLastScan = Date()
                    trendMeasurements = sensorData.trendMeasurements(bloodGlucoseOffset, slope: bloodGlucoseSlope)
                    historyMeasurements = sensorData.historyMeasurements(bloodGlucoseOffset, slope: bloodGlucoseSlope)
                    
                    if let trendMeasurements = trendMeasurements {
                        setBloodGlucoseHighOrLowNotificationIfNecessary(trendMeasurements: trendMeasurements)
                    }
                    
                    if let historyMeasurements = historyMeasurements,  sensorData.hasValidBodyCRC && sensorData.hasValidHeaderCRC && sensorData.state == .ready {
                        
                        // fetch all records that are newer than the oldest history measurement of the new data
                        let dateFormatter = DateFormatter()
                        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                        
                        let request = BloodGlucose.fetchRequest(from: Date(timeIntervalSinceNow: TimeInterval(-30600))) as NSFetchRequest<BloodGlucose> // 8.5 h = 30600 s
                        do {
                            let fetchedBloodGlucoses = try persistentContainer?.viewContext.fetch(request)
                            
                            
                            // Loop over all and check if new data exists and store the new data if not yet existent
                            historyMeasurements.forEach({measurement in
                                
                                os_log("HistoryMeasurement: %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, measurement.description)

                                var storeMeasurement = true
                                
                                // Check if there is already a record stored for the same time
                                for bloodGlucose in fetchedBloodGlucoses! {
                                    
                                    
                                    // Found a value within time range that is already stored, so do not store the value just read from the sensor (since it is already stored)
                                    // Time range criteria is fulfilled if dates of stored value and value just read from sensor are less than two minutes apart from each other (in either direction)
                                    if let bloodGlucoseDate = bloodGlucose.date, abs(bloodGlucoseDate.timeIntervalSince(measurement.date)) < 120.0 {
                                        
                                        os_log("Fetched Glucose %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: "\(bloodGlucose.value) at \(String(describing: bloodGlucose.date))"))
                                        os_log("Do not store: %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: "\(measurement.glucose) at \(String(describing: measurement.date))"))
                                        storeMeasurement = false
                                        break
                                    }
                                }
                                // Store if there isn't a measurement yet for this time and if it is a possible value (i.e. greater than zero and greater than offset)
                                if storeMeasurement && (bloodGlucoseOffset < measurement.glucose) && (0.0 < measurement.glucose) {
                                
                                    fetchedBloodGlucoses?.forEach({ bloodGlucose in
                                        os_log("Fetched Glucose %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: "\(bloodGlucose.value) at \(String(describing: bloodGlucose.date))"))
                                    })
                                    os_log("Store this one: %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, measurement.description)

                                    let glucose = BloodGlucose(context: (persistentContainer?.viewContext)!)
                                    glucose.bytes = measurement.byteString
                                    glucose.value = measurement.glucose
                                    glucose.date = measurement.date as NSDate
                                    glucose.dateString = dateFormatter.string(from: measurement.date)
                                    
                                    // Prepare for nightscout
                                    nightscoutEntries.append(NightscoutEntry(glucose: Int(measurement.glucose), timestamp: measurement.date, device: "LibreMonitor", glucoseType: .Sensor))
                                }
                            })
                            // send to nightscout
                            if UserDefaults.standard.bool(forKey: "uploadToNightscoutIsActivated") {
                                uploader?.processFreestyleLibreHistoryEntries(nightscoutEntries: nightscoutEntries)
                                nightscoutEntries = []
                            }
                            try? persistentContainer?.viewContext.save()
                            
                        } catch {
                            fatalError("Failed to fetch BloodGlucose: \(error)")
                        }
                    }

                }
                
                
            } else {
                trendMeasurements = nil
                historyMeasurements = nil
            }

        }
        tableView.reloadData()

    }
    
    
    
    // MARK: - SimbleeManagerDelegate 
    
    func simbleeManagerPeripheralStateChanged(_ state: SimbleeManagerState) {
        os_log("Simblee manager peripheral state changed to %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: state.rawValue))

        self.navigationItem.rightBarButtonItem?.title? = connectButtonTitleForState(state)
        
        switch state {
        case .Unassigned, .Connecting, .Connected, .Scanning, .DisconnectingDueToButtonPress, .Disconnected:
            NotificationManager.applicationIconBadgeNumber(value: 0) // Data not accurate any more -> remove badge icon
            NotificationManager.scheduleBluetoothDisconnectedNotification(wait: 400)
        case .Notifying:
            NotificationManager.removePendingBluetoothDisconnectedNotification()
        }
        tableView.reloadData()
    }
    
    
    func simbleeManagerReceivedMessage(_ messageIdentifier: UInt16, txFlags: UInt8, payloadData: Data) {
        
        os_log("Received message with identifier %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: messageIdentifier))
        NotificationManager.scheduleDataTransferInterruptedNotification(wait: 400)
        
        guard let receivedDataType = ReceivedDataType(rawValue: messageIdentifier) else {
            os_log("Received message with unknown identifier %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: messageIdentifier))
            return
        }
        os_log("Received data type: %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: receivedDataType.rawValue))
        
        switch receivedDataType {
        case .NFC_STATE:

            let nfcState = NFCState(bytes: payloadData)
            os_log("NFCState is %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: nfcState.nfcReady))

        
        case .SYSTEM_INFORMATION_DATA: // system information data, including UID (e.g. E0:07:A0:00:00:0C:48:BD")
            
            // Convention: System Information data is the first packet sent via bluetooth, thus delete all internal data and reload table view
            
            timeOfTransmissionStart = Date()
            nfcReadingStart = Date()
            deviceID = "-"
            
            let systemInformationData = SystemInformationDataType(bytes: payloadData)
            sensor = FreestyleLibreSensor(withUID: Data(systemInformationData.uidArray))
            os_log("System information data is %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: systemInformationData.description))

            //  Convention: System Information data is the first packet sent from RFDuino, thus delete all internal data and reload table view
            tableView.reloadData()

            
        case .BATTERY_DATA: // Battery
            
            nfcReadingDuration = Date().timeIntervalSince(nfcReadingStart)
            bluetoothTransmissionStart = Date()
            
            let battery = BatteryDataType(bytes: payloadData)

            batteryVoltage = Double(battery.voltage)
            temperatureString = String(format: "%4.1f °C", arguments: [battery.temperature])
            
            os_log("Battery data is %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: "\(battery.voltage) Volts and \(battery.temperature) °C"))

            if battery.voltage < 3.5 {
                NotificationManager.setLowBatteryNotification(voltage: Double(battery.voltage))
            }
            
            
        case .ALL_BYTES: // all data bytes (all 344 bytes, i.e. 43 blocks)
            
            var bytes = [UInt8](repeating: 0, count: 344)
            (payloadData as NSData).getBytes(&bytes, length: 344)
            
            sensorData = SensorData(bytes: bytes, date: Date())
            os_log("All bytes data is %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: sensorData.debugDescription))
            
            if let sennsorData = sensorData {
                trendMeasurements = sennsorData.trendMeasurements(bloodGlucoseOffset, slope: bloodGlucoseSlope)
                historyMeasurements = sennsorData.historyMeasurements(bloodGlucoseOffset, slope: bloodGlucoseSlope)

                if let trendMeasurements = trendMeasurements {
                    setBloodGlucoseHighOrLowNotificationIfNecessary(trendMeasurements: trendMeasurements)
                }

                if let historyMeasurements = historyMeasurements,  sennsorData.hasValidBodyCRC && sennsorData.hasValidHeaderCRC && sennsorData.state == .ready {
                   
                    // fetch all records that are newer than the oldest history measurement of the new data
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    
                    let request = BloodGlucose.fetchRequest(from: Date(timeIntervalSinceNow: TimeInterval(-30600))) as NSFetchRequest<BloodGlucose> // 8.5 h = 30600 s
                    do {
                        let fetchedBloodGlucoses = try persistentContainer?.viewContext.fetch(request)
                        
                        // Loop over all and check if new data exists and store the new data if not yet existent 
                        historyMeasurements.forEach({measurement in
                            
                            var storeMeasurement = true
                            
                            // Check if there is already a record stored for the same time
                            for bloodGlucose in fetchedBloodGlucoses! {

                                // Store value if dates are less than two minutes apart from each other (in either direction)
                                if let bloodGlucoseDate = bloodGlucose.date, abs(bloodGlucoseDate.timeIntervalSince(measurement.date)) < 2.0 * 60.0 {
                                    storeMeasurement = false
                                    break
                                }
                            }
                            // Store if there isn't a measurement yet for this time and if it is a possible value (i.e. greater than zero and greater than offset)
                            if storeMeasurement && (bloodGlucoseOffset < measurement.glucose) && (0.0 < measurement.glucose) {
                                let glucose = BloodGlucose(context: (persistentContainer?.viewContext)!)
                                glucose.bytes = measurement.byteString
                                glucose.value = measurement.glucose
                                glucose.date = measurement.date as NSDate
                                glucose.dateString = dateFormatter.string(from: measurement.date)

                                // Prepare for nightscout
                                nightscoutEntries.append(NightscoutEntry(glucose: Int(measurement.glucose), timestamp: measurement.date, device: "LibreMonitor", glucoseType: .Sensor))
                            }
                        })
                        // send to nightscout
                        if UserDefaults.standard.bool(forKey: "uploadToNightscoutIsActivated") {
                            uploader?.processFreestyleLibreHistoryEntries(nightscoutEntries: nightscoutEntries)
                            nightscoutEntries = []
                        }
                        try? persistentContainer?.viewContext.save()
 
                    } catch {
                        fatalError("Failed to fetch BloodGlucose: \(error)")
                    }
                }
                
            } else {
                trendMeasurements = nil
                historyMeasurements = nil
            }
            tableView.reloadData()
            
            
        case .IDN_DATA: // IDN data, including device ID, example: RESPONSE CODE: 0 LENGTH: 15, DEVICE ID: 4E 46 43 20 46 53 32 4A 41 53 54 32 0, ROM CRC: 75D2
            
            let idnData = IDNDataType(bytes: payloadData)
            self.deviceID = idnData.idPrettyString
            
            os_log("Idn data is \n%{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: idnData.description))

            
            timeOfLastScan = Date()
            transmissionDuration = Date().timeIntervalSince(timeOfTransmissionStart)
            bluetoothTransmissionDuration = Date().timeIntervalSince(bluetoothTransmissionStart)
            
            // Convention: the idn data is the last packet sent from RFDuino within a cycle, thus reload table view after having received it
            tableView.reloadData()
                        
        }
        os_log("Blood sugar table view controller handled message with identifier %{public}@", log: BloodSugarTableViewController.bt_log, type: .default, String(describing: messageIdentifier))
    }
    
    
    // MARK: - Helper functions
    
    func colorForConnectionState() -> UIColor {
        switch (simbleeManager.state) {
        case .Unassigned, .Disconnected, .DisconnectingDueToButtonPress:
            return UIColor.red
        case .Scanning, .Connecting, .Connected:
            return UIColor(red: CGFloat(0.9), green: CGFloat(0.9), blue: CGFloat(1), alpha: CGFloat(1))
        case .Notifying:
            return UIColor.green
        }
    }

    func colorForConnectionMiaoMiaoState() -> UIColor {
        switch (miaoMiaoManager.state) {
        case .Unassigned, .Disconnected, .DisconnectingDueToButtonPress:
            return UIColor.red
        case .Scanning, .Connecting, .Connected:
            return UIColor(red: CGFloat(0.9), green: CGFloat(0.9), blue: CGFloat(1), alpha: CGFloat(1))
        case .Notifying:
            return UIColor.green
        }
    }

    func colorForSensorState(_ bool: Bool) -> UIColor {
        if bool == false {
            return UIColor.red
        }
        return UIColor.white
    }
    
    func connectButtonTitleForState(_ state: SimbleeManagerState) -> String {
        
        switch state {
        case .Unassigned, .Disconnected, .DisconnectingDueToButtonPress:
            return "connect"
        case .Connected, .Connecting, .Scanning, .Notifying:
            return "disconnect"
        }
    }
    
    func connectButtonTitleForMiaoMiaoState(_ state: MiaoMiaoManagerState) -> String {
        
        switch state {
        case .Unassigned, .Disconnected, .DisconnectingDueToButtonPress:
            return "connect"
        case .Connected, .Connecting, .Scanning, .Notifying:
            return "disconnect"
        }
    }
    
    // MARK: - Notifications and badge icon
    
    func setBloodGlucoseHighOrLowNotificationIfNecessary(trendMeasurements: [Measurement] ) {

        let currentGlucose = trendMeasurements[0].glucose
        let longDelta = currentGlucose - trendMeasurements[15].glucose
        let shortDelta = (currentGlucose - trendMeasurements[8].glucose) * 2.0 * 16.0/15.0
        let longPrediction = currentGlucose + longDelta
        let shortPrediction = currentGlucose + shortDelta
        
        // Show high blood glucose alert if conditions are reached
        if (longPrediction > 180.0) || (shortPrediction > 180.0) || (longDelta > 30.0 && shortDelta > 30.0) {
            
            let body = String(format: "%0.0f --> %0.0f (%0.0f), Delta: %0.0f (%0.0f)", arguments: [currentGlucose, longPrediction, shortPrediction, longDelta, shortDelta])
            NotificationManager.setBloodGlucoseHighOrLowNotification(title: "High Glucose", body: body)
            
        } else if (longPrediction > 0 && longPrediction < 60.0 ) || (shortPrediction > 0 && shortPrediction < 66.0 ) || (longDelta < -30.0 && shortDelta < -30.0) {
            
            let body = String(format: "%0.0f --> %0.0f (%0.0f), Delta: %0.0f (%0.0f)", arguments: [currentGlucose, longPrediction, shortPrediction, longDelta, shortDelta])
            NotificationManager.setBloodGlucoseHighOrLowNotification(title: "Low Glucose", body: body)
        }
        NotificationManager.applicationIconBadgeNumber(value: Int(round(longPrediction)))
        
//        // Show corresponding app icon
//        NotificationManager.setAlternativeAppIconForGlucoseDelta(longDelta)
    }
    
    
    
    
    /// Gets glucose value from OOP web interface from @dabear.
    ///
    /// Gets glucose value from real Abbott algorithm for Freestyle Libre by sending data to a webserver that itself sends the data to an Android phone that calculates the glucose value from the fram data by using the LibreLink Android app (or apk).
    ///
    /// Since this is async: A closure will be called, when the value arrives and the glucose value will then be stored in a local variable of the view controller.
    ///
    /// - Parameter fram: 344 bytes of fram of the Freestyle Libre sensor
    func getOOPGlucose(fram: [UInt8]) {
        
        // OOP Webinterface
        if UserDefaults.standard.bool(forKey: "useOOPWebInterfaceIsActivated") {
            
            oopCurrentValue = nil
            if let accessToken = UserDefaults.standard.string(forKey: "oopWebInterfaceAPIToken"),
                let site = UserDefaults.standard.string(forKey: "oopWebInterfaceSite") {
                
                let oopClient = LibreOOPClient(accessToken: accessToken, site: site)
                
                oopClient.uploadReading(reading: fram) { (response, success, errormessage) in
                    guard success else {
                        NSLog("remote: upload reading failed! \(errormessage)")
                        return
                    }
                    
                    if let response = response, let uuid = response.result?.uuid {
                        print("uuid received: " + uuid)
                        
                        // The completion handler will be called once the result is available, or when a timeout is received
                        // The timeout can be calculated as approx (intervalSeconds * maxTries) seconds
                        // In case of timeout, the success parameter will be false, errormessage will have contents
                        // and the response will be "N/A"
                        // In case of success, response will be a string containing the result of the Algorithm
                        oopClient.getStatusIntervalled(uuid: uuid, { (success, errormessage, response) in
                            
                            //"some value from android: currentBg: 170"
                            if let jsonStringStartIndex = response.range(of: "FullAlgoResults: ")?.upperBound {
                                
                                do {
                                    let jsonString = response.suffix(from: jsonStringStartIndex)
                                    let jsonData = String(jsonString).data(using: .utf8)!
                                    self.oopCurrentValue = try JSONDecoder().decode(OOPCurrentValue.self, from: jsonData)

//                                    print("\nRelevant json string: \n\(jsonString)")
//                                    print("Decoded content")
//                                    print("  Current trend: \(oopCurrentValue.currentTrend)")
//                                    print("  Current bg: \(oopCurrentValue.currentBg)")
//                                    print("  Current time: \(oopCurrentValue.currentTime)")
//                                    print("  Serial Number: \(oopCurrentValue.serialNumber ?? "-")")
//                                    print("  timeStamp: \(oopCurrentValue.timestamp)")
//                                    var i = 0
//                                    for historyValue in oopCurrentValue.historyValues {
//                                        print(String(format: "    #%02d: time: \(historyValue.time), quality: \(historyValue.quality), bg: \(historyValue.bg)", i))
//                                        i += 1
//                                    }
                                } catch let error {
                                    print("Error", error)
                                }
                            }

                            NSLog("GetStatusIntervalled returned with success?: \(success), error: \(errormessage), response: \(response))")
                        })
                    }
                }
            }
        }
    }
    
}






