// A toy example to show the benefit of loopsum
//
// 2 loop summaries in this example.
// Both in the same in-loop branch but different guard.

#include <stdio.h>
#include <stdlib.h>

int input;

void func(int x){
    char str[30];
    int c = 0;
    while (1){
	x = x - 3; 	/* IV1 */
	c = c + 2;	/* IV2 */
	if (x == 7)	/* Guard */
	    break;
    }

    if (c <= 33){		/* overwrite main()'s return addr when input >= 34*/
	str[c] = 0;
    }
}

int main(int argc, char **argv){
    func(input);
    return 0;
}
