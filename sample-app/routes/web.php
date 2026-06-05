<?php

use App\Models\Counter;
use Illuminate\Support\Facades\Route;

/*
|--------------------------------------------------------------------------
| Web Routes
|--------------------------------------------------------------------------
|
| Here is where you can register web routes for your application. These
| routes are loaded by the RouteServiceProvider within a group which
| contains the "web" middleware group. Now create something great!
|
*/

Route::get('/', function () {
    $value = Counter::sum('count');
    return view('welcome', ['value' => $value]);
});

// Demo endpoint: burns CPU for ~5 s to trigger HPA scaling during load tests.
Route::get('/cpu', function () {
    $start = microtime(true);
    while (microtime(true) - $start < 5.0) {
        for ($i = 0; $i < 50000; $i++) {
            sqrt(rand());
        }
    }
    return response()->json(['status' => 'cpu spike done', 'duration_s' => 5]);
});

// Demo endpoint: leaks memory in 10 MB chunks to push the pod toward its
// container memory limit — used to show RSS climbing in Grafana and, past the
// limit, an OOMKill + automatic pod restart.
//   ?mb=256    total megabytes to allocate (default 256)
//   ?hold=30   seconds to hold the memory before releasing (default 30)
Route::get('/leak', function (\Illuminate\Http\Request $request) {
    // Let the *container* memory limit be the ceiling, not PHP's memory_limit,
    // so the pod is what gets OOMKilled — that's the failure we want to demo.
    ini_set('memory_limit', '-1');

    $targetMb = max(10, (int) $request->query('mb', 256));
    $holdS    = max(0, (int) $request->query('hold', 30));

    // str_repeat forces a real allocation that can't be optimised away; the
    // chunks stay referenced for the whole request so the RSS keeps growing.
    $chunks = [];
    for ($i = 0; $i < intdiv($targetMb, 10); $i++) {
        $chunks[] = str_repeat('x', 10 * 1024 * 1024); // 10 MB
        usleep(100_000); // 0.1 s — let the climb render on the metrics graph
    }

    $allocatedMb = (int) round(memory_get_usage(true) / 1024 / 1024);
    sleep($holdS); // hold the memory so it's visible / triggers the OOMKill

    return response()->json([
        'status'       => 'memory leak done',
        'allocated_mb' => $allocatedMb,
        'held_s'       => $holdS,
    ]);
});
