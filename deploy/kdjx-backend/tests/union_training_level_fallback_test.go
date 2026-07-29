package union

import "testing"

func TestNearestConfiguredLevel(t *testing.T) {
	tests := []struct {
		name      string
		requested int
		levels    []int
		want      int
		wantOK    bool
	}{
		{name: "exact", requested: 5, levels: []int{10, 1, 5}, want: 5, wantOK: true},
		{name: "gap", requested: 7, levels: []int{10, 1, 5}, want: 5, wantOK: true},
		{name: "above maximum", requested: 112, levels: []int{111, 1, 99}, want: 111, wantOK: true},
		{name: "below minimum", requested: 0, levels: []int{10, 1, 5}, want: 1, wantOK: true},
		{name: "empty", requested: 112, levels: nil, want: 0, wantOK: false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, ok := nearestConfiguredLevel(test.requested, test.levels)
			if got != test.want || ok != test.wantOK {
				t.Fatalf(
					"nearestConfiguredLevel(%d, %v) = (%d, %t), want (%d, %t)",
					test.requested,
					test.levels,
					got,
					ok,
					test.want,
					test.wantOK,
				)
			}
		})
	}
}
