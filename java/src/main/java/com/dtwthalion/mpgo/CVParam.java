/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

// CV (controlled vocabulary) parameter — used for ontology-based annotation
public record CVParam(String ontologyRef, String accession, String name, String value, String unit) {}
