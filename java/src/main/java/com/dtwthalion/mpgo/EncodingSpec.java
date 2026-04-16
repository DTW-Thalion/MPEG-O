/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.Enums.Precision;
import com.dtwthalion.mpgo.Enums.Compression;
import com.dtwthalion.mpgo.Enums.ByteOrder;

public record EncodingSpec(Precision precision, Compression compression, ByteOrder byteOrder) {}
