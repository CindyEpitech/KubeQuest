<?php

namespace App\Http\Controllers;

use App\Models\Counter;

class CounterController extends Controller
{
    public function add()
    {
        $counter = new Counter();
        $counter->count = 1;
        $counter->save();
        $value = Counter::sum('count');
        return response()->json(["value" => $value], 200);
    }

    public function subtract()
    {
        // Each "add" stores a +1 row, and the column is unsigned, so we
        // decrement by removing one row rather than inserting a -1. The
        // counter floors at 0 once there are no rows left to delete.
        $row = Counter::query()->latest('id')->first();
        if ($row) {
            $row->delete();
        }
        $value = Counter::sum('count');
        return response()->json(["value" => $value], 200);
    }

    public function reset()
    {
        Counter::query()->delete();
        $value = Counter::sum('count');
        return response()->json(["value" => $value], 200);
    }

    public function get()
    {
        $value = Counter::sum('count');
        return response()->json(["value" => $value], 200);
    }
}
