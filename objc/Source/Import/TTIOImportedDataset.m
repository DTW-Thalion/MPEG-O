/*
 * TTIOImportedDataset.m
 * TTI-O Objective-C Implementation
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "Import/TTIOImportedDataset.h"
#import "Dataset/TTIOSpectralDataset.h"

@implementation TTIOImportedDataset

- (instancetype)init
{
    self = [super init];
    if (self) {
        _title = @"";
        _isaInvestigationId = @"";
        _msRuns = [[NSMutableDictionary alloc] init];
        _genomicRuns = [[NSMutableDictionary alloc] init];
        _identifications = [[NSMutableArray alloc] init];
        _quantifications = [[NSMutableArray alloc] init];
        _provenanceRecords = [[NSMutableArray alloc] init];
    }
    return self;
}

+ (instancetype)datasetWithWriteDelegate:(TTIOImportedDatasetWriteDelegate)delegate
{
    TTIOImportedDataset *ds = [[self alloc] init];
    ds.writeDelegate = delegate;
    return ds;
}

- (BOOL)writeToPath:(NSString *)path error:(NSError *_Nullable *_Nullable)error
{
    // Write-through delegate (subprocess / image importers) wins.
    if (self.writeDelegate) {
        return self.writeDelegate(path, error);
    }

    // In-memory draft -> canonical mixed-dictionary write API. Images are
    // NOT written here (writeMinimal has no image parameter); they are
    // persisted by the imzML adapter's write-through delegate (OT5).
    NSString *title = (self.title.length ? self.title : @"imported");
    NSDictionary<NSString *, id> *genomic =
        (self.genomicRuns.count ? self.genomicRuns : nil);
    NSArray *idents = (self.identifications.count ? self.identifications : nil);
    NSArray *quants = (self.quantifications.count ? self.quantifications : nil);
    NSArray *prov   = (self.provenanceRecords.count ? self.provenanceRecords : nil);

    return [TTIOSpectralDataset writeMinimalToPath:path
                                             title:title
                                isaInvestigationId:self.isaInvestigationId
                                         mixedRuns:self.msRuns
                                       genomicRuns:genomic
                                   identifications:idents
                                   quantifications:quants
                                 provenanceRecords:prov
                                             error:error];
}

@end
