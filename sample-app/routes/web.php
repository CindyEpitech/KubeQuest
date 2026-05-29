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
