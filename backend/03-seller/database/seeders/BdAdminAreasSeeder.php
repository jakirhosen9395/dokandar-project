<?php

namespace Database\Seeders;

use Illuminate\Database\Seeder;
use Illuminate\Support\Facades\DB;

/**
 * Representative Bangladesh administrative-areas seed (v2.0 §3.5).
 *
 * The full open dataset is ~5000 union/thana rows; for this teaching
 * deployment we seed all 8 divisions plus a deep set of districts /
 * upazilas / unions under Dhaka + Chittagong (enough for the cascading
 * picker happy path) and one district per remaining division. Idempotent:
 * skips entirely when the table is already populated.
 */
class BdAdminAreasSeeder extends Seeder
{
    public function run(): void
    {
        if (DB::table('bd_admin_areas')->count() > 0) {
            return;
        }

        // division => district => upazila => [ union_thana, lat, lon ]
        $tree = [
            'Dhaka' => [
                'Dhaka' => [
                    'Dhanmondi'  => [['Dhanmondi', 23.745, 90.376], ['Hazaribagh', 23.745, 90.366]],
                    'Gulshan'    => [['Gulshan 1', 23.780, 90.416], ['Gulshan 2', 23.793, 90.414], ['Banani', 23.793, 90.404]],
                    'Mirpur'     => [['Mirpur 10', 23.807, 90.368], ['Mirpur 1', 23.798, 90.353]],
                    'Motijheel'  => [['Motijheel', 23.726, 90.418]],
                    'Uttara'     => [['Sector 7', 23.866, 90.401]],
                ],
                'Gazipur' => [
                    'Tongi'         => [['Tongi', 23.890, 90.405]],
                    'Gazipur Sadar' => [['Gazipur Sadar', 23.999, 90.420]],
                ],
                'Narayanganj' => [
                    'Narayanganj Sadar' => [['Narayanganj Sadar', 23.623, 90.500]],
                ],
            ],
            'Chittagong' => [
                'Chittagong' => [
                    'Panchlaish' => [['Panchlaish', 22.360, 91.834]],
                    'Agrabad'    => [['Agrabad', 22.327, 91.812]],
                    'Khulshi'    => [['Khulshi', 22.360, 91.810]],
                ],
                "Cox's Bazar" => [
                    "Cox's Bazar Sadar" => [["Cox's Bazar Sadar", 21.433, 92.008]],
                ],
            ],
            'Barisal'    => ['Barisal'    => ['Barisal Sadar'    => [['Barisal Sadar', 22.701, 90.353]]]],
            'Khulna'     => ['Khulna'     => ['Khulna Sadar'     => [['Khulna Sadar', 22.845, 89.540]]]],
            'Rajshahi'   => ['Rajshahi'   => ['Rajshahi Sadar'   => [['Rajshahi Sadar', 24.374, 88.604]]]],
            'Rangpur'    => ['Rangpur'    => ['Rangpur Sadar'    => [['Rangpur Sadar', 25.746, 89.252]]]],
            'Mymensingh' => ['Mymensingh' => ['Mymensingh Sadar' => [['Mymensingh Sadar', 24.747, 90.420]]]],
            'Sylhet'     => ['Sylhet'     => ['Sylhet Sadar'     => [['Sylhet Sadar', 24.899, 91.870]]]],
        ];

        $rows = [];
        foreach ($tree as $division => $districts) {
            foreach ($districts as $district => $upazilas) {
                foreach ($upazilas as $upazila => $unions) {
                    foreach ($unions as [$union, $lat, $lon]) {
                        $rows[] = [
                            'division'     => $division,
                            'district'     => $district,
                            'upazila'      => $upazila,
                            'union_thana'  => $union,
                            'lat_centroid' => $lat,
                            'lon_centroid' => $lon,
                        ];
                    }
                }
            }
        }

        foreach (array_chunk($rows, 200) as $chunk) {
            DB::table('bd_admin_areas')->insert($chunk);
        }
    }
}
