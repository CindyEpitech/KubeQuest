<?php

namespace Tests\Unit;

use PHPUnit\Framework\TestCase;

/**
 * Deliberate failing test to verify the CI gate blocks a PR into develop.
 * Remove this file once the experiment is done.
 */
class CiGateTest extends TestCase
{
    /** @test */
    public function it_fails_on_purpose()
    {
        $this->assertTrue(false, 'Intentional failure to test the CI gate.');
    }
}
