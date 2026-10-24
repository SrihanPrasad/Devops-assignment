package com.example;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

/** Unit tests - run by surefire during "mvn test". */
class CalculatorTest {

    @Test
    void addsTwoNumbers() {
        assertEquals(5, Calculator.add(2, 3));
    }

    @Test
    void addsNegativeNumbers() {
        assertEquals(-1, Calculator.add(2, -3));
    }

    @Test
    void multipliesTwoNumbers() {
        assertEquals(12, Calculator.multiply(3, 4));
    }
}
