import NoonmarkDiagnostics

extension ICloudDriveSyncTransportError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        let code = switch self {
        case .unavailable: 101
        case .accountUnavailable: 102
        case .driveUnavailable: 103
        }
        return DiagnosticFailure(domain: .syncProtocol, code: code)
    }
}

extension SyncRecordTransportError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        let code = switch self {
        case .immutableRecordCollision: 201
        case let .invalidCurrentRecordMerge(_, reason):
            reason.diagnosticCode
        }
        return DiagnosticFailure(domain: .syncProtocol, code: code)
    }
}

extension SyncRecordMergeFailureReason {
    /// Merge-rejection subcodes occupy the 250-259 block of the syncProtocol
    /// domain; 202 remains the fallback when no typed reason was preserved.
    /// Codes identify only the violated merge rule — never record identity,
    /// entity content, timestamps, or free text.
    var diagnosticCode: Int {
        switch self {
        case .unknown: 202
        case .inconsistentRecordHeaders: 250
        case .invalidContentClock: 251
        case .taskCycleSeriesIdentityCollision: 252
        case .taskChainIdentityCollision: 253
        case .taskDefinitionIdentityCollision: 254
        case .dayTraceIdentityCollision: 255
        case .invalidReactivationWitnesses: 256
        case .invalidNoteEntries: 257
        case .noteEntryCreatedAtCollision: 258
        case .invalidRecordPayload: 259
        }
    }
}

extension CloudKitSyncEngineTransportError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        let code = switch self {
        case .accountUnavailable: 301
        case .accountChanged: 302
        case .invalidEngineState: 303
        case .invalidServerRecordSystemFields: 304
        case .unexpectedRemoteRecordDeletion: 305
        case .recordZoneDeleted: 306
        case .liveValidationZoneRequired: 307
        case .syncScopeChanged: 308
        case .cloudKitFailure: 309
        case .missingEntitlement: 310
        }
        return DiagnosticFailure(domain: .cloudKit, code: code)
    }
}

extension CloudKitSyncLaunchConfigurationError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        DiagnosticFailure(domain: .cloudKit, code: 320)
    }
}

extension CloudKitSyncPersistenceError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        let code = switch self {
        case .duplicateRecordID: 331
        case .invalidSnapshot: 332
        case .inactiveLease: 333
        }
        return DiagnosticFailure(domain: .cloudKit, code: code)
    }
}

extension CloudKitSyncRecordCodecError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        let code = switch self {
        case .unexpectedRecordType: 341
        case .unexpectedRecordZone: 342
        case .unexpectedFieldSet: 343
        case .unsupportedFormatVersion: 344
        case .missingRequiredField: 345
        case .digestMismatch: 346
        case .invalidWirePayload: 347
        case .noncanonicalWirePayload: 348
        case .syncRecordIDMismatch: 349
        case .recordNameMismatch: 350
        }
        return DiagnosticFailure(domain: .cloudKit, code: code)
    }
}

extension CloudKitSyncMirrorError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        let code = switch self {
        case .invalidPersistedCurrentRecord: 361
        case .ambiguousServerRecordSystemFields: 362
        }
        return DiagnosticFailure(domain: .cloudKit, code: code)
    }
}

extension SyncRecordMapperError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        let code = switch self {
        case .entityTypeMismatch: 401
        case .invalidPayload: 402
        case .classificationStateRequiresCommitRecords: 403
        }
        return DiagnosticFailure(domain: .syncProtocol, code: code)
    }
}

extension SyncRecordMaterializerError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        let code = switch self {
        case .missingEntity: 411
        case .unsupportedDelete: 412
        case .invalidJournalPayload: 413
        case .invalidImmutablePayload: 414
        }
        return DiagnosticFailure(domain: .syncProtocol, code: code)
    }
}

extension SyncSnapshotDifferError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        let code = switch self {
        case .classificationHistoryDiverged: 421
        case .classificationCommitsMustBePersistedIndividually: 422
        case .unsupportedClassificationTransition: 423
        case .invalidChainReactivationBoundary: 424
        case .invalidThemeLanguageClock: 425
        case .themeLanguageClockDidNotAdvance: 426
        case .themeLanguageClockChangedWithoutValues: 427
        case .themeLanguageClockDoesNotMatchJournal: 428
        }
        return DiagnosticFailure(domain: .syncProtocol, code: code)
    }
}

extension SyncRepositorySnapshotError: DiagnosticFailureProviding {
    public var diagnosticFailure: DiagnosticFailure {
        DiagnosticFailure(domain: .syncProtocol, code: 431)
    }
}
