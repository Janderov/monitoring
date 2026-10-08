package main

import (
	"fmt"
	"reflect"
	"testing"
)

func TestErrorLogOnlyChanges(t *testing.T) {
	var got []string
	logf := func(f string, a ...any) { got = append(got, fmt.Sprintf(f, a...)) }
	var l errorLog
	l.note([]string{"docker: timeout"}, logf)
	l.note([]string{"docker: timeout"}, logf)
	l.note([]string{"docker: timeout", "ssh log: denied"}, logf)
	l.note(nil, logf)
	l.note(nil, logf)
	want := []string{"sample: docker: timeout", "sample: ssh log: denied"}
	if !reflect.DeepEqual(got[:2], want) || len(got) != 4 {
		t.Fatalf("logged %q", got)
	}
}
