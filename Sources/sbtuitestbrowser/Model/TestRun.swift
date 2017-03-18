//
// TestRun.swift
//
// Copyright (C) 2016 Subito.it S.r.l (www.subito.it)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.


import Foundation

class TestRun: ListItem, FailableItem {
    let plistURL: URL
    let screencastURL: URL?
    var id: String { return plistURL.lastPathComponent }
    
    private(set) var deviceName: String = ""
    private(set) var suites = [TestSuite]()
    
    init(plistURL: URL) {
        self.plistURL = plistURL
        self.screencastURL = plistURL.deletingLastPathComponent().appendingPathComponent("SessionQT.mp4")
        super.init()
        self.parse()
    }
    
    static func parse(plists: [URL], partialRun: @escaping (TestRun, Double) -> Void ) -> [TestRun] {
        var runs = [TestRun]()
        
        let synchQueue = DispatchQueue(label: "com.synch.parse")
        // parallel enumeration
        (plists as NSArray).enumerateObjects(options: .concurrent, using: { (obj, idx, stop) -> Void in
            autoreleasepool {
                let run = TestRun(plistURL: obj as! URL)
                
                synchQueue.async {
                    runs.append(run)
                    partialRun(run, Double(runs.count) / Double(plists.count))
                }
            }
        })
        
        return runs
    }
    
    public func createdString() -> String {
        let attr = try? FileManager.default.attributesOfItem(atPath: plistURL.path)
        if let date = attr?[FileAttributeKey.modificationDate] as? Date {
            return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
        }
        
        return ""
    }
    
    public func add(_ suites: [TestSuite]) {
        var mSuites = self.suites + suites
        
        mSuites.sort(by: { $0.tests.first?.startTimeinterval ?? 0 < $1.tests.first?.startTimeinterval ?? 0 })
        mSuites.listify()
        
        self.suites = mSuites
    }
    
    public func totalTests(errorsOnly: Bool) -> Int {
        return suites.reduce(0) { $0 + $1.totalTests(errorsOnly: errorsOnly) }
    }
    
    public func totalSuites(errorsOnly: Bool) -> Int {
        if errorsOnly {
            return suites.filter({ $0.hasFailure() }).count
        } else {
            return suites.count
        }
    }
    
    public func totalDuration() -> TimeInterval {
        return suites.reduce(0) { $0 + $1.totalDuration() }
    }
    
    public func suite(named: String) -> TestSuite? {
        return suites.first(where: { $0.name == named})
    }
    
    public func failingSuites() -> [TestSuite] {
        return suites.filter { $0.hasFailure() }
    }
    
    public func failingTests() -> [Test] {
        return suites.reduce([Test]()) { $0 + $1.failingTests() }
    }
    
    // MARK: - Private
    
    private func parse() {
        guard let dict = NSDictionary(contentsOf: self.plistURL) as? [String : Any] else {
            fatalError("Failed to load dictionary")
        }
        guard extract(formatVersion: dict) == "1.2" else {
            fatalError("Unsupported format version, expected 1.2")
        }
        
        let deviceName = extract(runDestination: dict)
        let testsDict = extract(testableSummaries: dict)
        
        let runSuites = suites(from: testsDict).map {
            suite in
                autoreleasepool {
                    let suiteTests = tests(from: testsDict, suite: suite)
  
                    suite.add(suiteTests)
                    return suite
                }
            } as [TestSuite]
        
        self.add(runSuites)
        
        self.deviceName = deviceName
    }
    
    private func suites(from dicts: [[String : Any]]) -> [TestSuite] {
        var ret = Set<TestSuite>()
        dicts.forEach { ret.insert(TestSuite(dict: $0, parentRun: self)) }
        
        return Array(ret)
    }
    
    private func tests(from dicts: [[String : Any]], suite: TestSuite) -> [Test] {
        func actions(from dicts: [[String : Any]], parentAction: TestAction?, parentTest: Test) -> [TestAction] {
            var ret = [TestAction]()
            
            for dict in dicts {
                let action = TestAction(dict: dict, parentAction: parentAction, parentTest: parentTest)
                
                ret.append(action)
                
                if let subActivities = dict["SubActivities"] as? [[String : Any]] {
                    ret += actions(from: subActivities, parentAction: action, parentTest: parentTest)
                }
            }
            
            return ret
        }
        
        var ret = [Test]()
        
        dicts.filter({ $0["ParentTestName"] as! String == suite.name }).forEach {
            testDict in
            
            let test = Test(dict: testDict, parentSuite: suite)
            
            if let activitySummaries = testDict["ActivitySummaries"] as? [[String : Any]] {
                test.add(actions(from: activitySummaries, parentAction: nil, parentTest: test))
            }
            
            ret.append(test)
        }
        
        return ret
    }
    
    private func extract(formatVersion dict: [String : Any]?) -> String {
        guard let formatVersion = dict?["FormatVersion"] as? String else {
            fatalError("No FormatVersion?")
        }
        
        return formatVersion
    }
    
    private func extract(runDestination dict: [String : Any]?) -> String {
        guard let dict = dict?["RunDestination"] as? [String : Any] else {
            fatalError("No RunDestination?")
        }
        guard let targetDevice = dict["TargetDevice"] as? [String : Any] else {
            fatalError("Unsupported RunDestination format, TargetDevice")
        }
        guard let localComputer = dict["LocalComputer"] as? [String : Any] else {
            fatalError("Unsupported RunDestination format, LocalComputer")
        }
        guard let targetSDK = dict["TargetSDK"] as? [String : Any] else {
            fatalError("Unsupported RunDestination format, TargetSDK")
        }
        
        _ = localComputer["suppresswarning"]
        _ = targetSDK["suppresswarning"]
        
        // for the time being we just extract the device name
        return targetDevice["Name"] as! String
    }
    
    private func extract(testableSummaries dict: [String : Any]?) -> [[String : Any]] {
        func extract(subTestLeafes dict: [String : Any]?, parent: [String : Any]?) -> [[String : Any]] {
            guard var dict = dict else {
                return []
            }
            var ret = [[String : Any]]()
            if let subtests = dict["Subtests"] as? [[String : Any]] {
                subtests.forEach { ret += extract(subTestLeafes: $0, parent: dict) }
            } else {
                dict["ParentTestName"] = parent?["TestName"]
                return [dict]
            }
            
            return ret
        }
        
        guard let summaries = dict?["TestableSummaries"] as? [[String : Any]] else {
            fatalError("No TestableSummaries?")
        }
        
        assert(summaries.count == 1) // we support just one here
        
        guard let tests = summaries.first?["Tests"] as? [[String : Any]]  else {
            fatalError("No Tests in TestableSummaries?")
        }
        
        assert(tests.count < 2) // we support just one here
        
        if tests.count == 0 {
            return []
        }
        
        return extract(subTestLeafes: tests.first!, parent: nil)
    }
    
    // MARK: - Protocols
    
    func hasFailure() -> Bool {
        return suites.reduce(false) { $0 || $1.hasFailure() }
    }
}

extension Array where Element: TestRun {
    
    func frequentlyFailingTests(minRunsForFrequentFail: Int) -> [Test] {
        func cleanupName(action: TestAction?) -> String? {
            guard let action = action else {
                return nil
            }
            let actionName = action.name
            let regex = try? NSRegularExpression(pattern: "<XC.*>", options: .caseInsensitive)
            let range = NSMakeRange(0, actionName.characters.count)
            
            return regex?.stringByReplacingMatches(in: actionName, options: [], range: range, withTemplate: "")
        }
        
        var frequentFailingTests = [Test]()
        
        outer: for failingTest0 in self[0].failingTests() {
            guard let failingTestAction0 = cleanupName(action: failingTest0.firstFailingAction()) else {
                continue
            }
            
            for i in 1..<minRunsForFrequentFail {
                if let failingTestI = self[i].failingTests().first(where: { $0 == failingTest0 }) {
                    guard let failingTestActionI = cleanupName(action: failingTestI.firstFailingAction()) else {
                        continue
                    }
                    
                    if failingTestAction0 == failingTestActionI {
                        continue
                    }
                }
                continue outer
            }
            frequentFailingTests.append(failingTest0)
        }
        
        return frequentFailingTests
    }
}
