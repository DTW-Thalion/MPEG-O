/*
 * MPEG-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package com.dtwthalion.mpgo;

import com.dtwthalion.mpgo.protocols.CVAnnotatable;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Method;
import java.util.Set;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.assertTrue;

class ProtocolsTest {

    @Test
    void cvAnnotatableSurface() {
        Set<String> names = methodNames(CVAnnotatable.class);
        assertTrue(names.contains("addCvParam"), "missing addCvParam");
        assertTrue(names.contains("removeCvParam"), "missing removeCvParam");
        assertTrue(names.contains("allCvParams"), "missing allCvParams");
        assertTrue(names.contains("cvParamsForAccession"), "missing cvParamsForAccession");
        assertTrue(names.contains("cvParamsForOntologyRef"), "missing cvParamsForOntologyRef");
        assertTrue(names.contains("hasCvParamWithAccession"), "missing hasCvParamWithAccession");
    }

    @Test
    void encryptableSurface() {
        Set<String> names = methodNames(
            com.dtwthalion.mpgo.protocols.Encryptable.class);
        assertTrue(names.contains("encryptWithKey"));
        assertTrue(names.contains("decryptWithKey"));
        assertTrue(names.contains("accessPolicy"));
        assertTrue(names.contains("setAccessPolicy"));
    }

    private static Set<String> methodNames(Class<?> c) {
        return java.util.Arrays.stream(c.getMethods())
            .map(Method::getName)
            .collect(Collectors.toSet());
    }

    @Test
    void indexableSurface() {
        Set<String> names = methodNames(
            com.dtwthalion.mpgo.protocols.Indexable.class);
        assertTrue(names.contains("objectAtIndex"));
        assertTrue(names.contains("count"));
        assertTrue(names.contains("objectForKey"));
        assertTrue(names.contains("objectsInRange"));
    }

    @Test
    void provenanceableSurface() {
        Set<String> names = methodNames(
            com.dtwthalion.mpgo.protocols.Provenanceable.class);
        assertTrue(names.contains("addProcessingStep"));
        assertTrue(names.contains("provenanceChain"));
        assertTrue(names.contains("inputEntities"));
        assertTrue(names.contains("outputEntities"));
    }

    @Test
    void streamableSurface() {
        Set<String> names = methodNames(
            com.dtwthalion.mpgo.protocols.Streamable.class);
        assertTrue(names.contains("nextObject"));
        assertTrue(names.contains("hasMore"));
        assertTrue(names.contains("currentPosition"));
        assertTrue(names.contains("seekToPosition"));
        assertTrue(names.contains("reset"));
    }
}
