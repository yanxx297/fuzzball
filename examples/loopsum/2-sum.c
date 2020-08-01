// A toy example to show the benefit of loopsum
//
// 2 loop summaries, one depend on the successful summarization of another
// Both in the same in-loop branch but different guard.

#include <stdio.h>
#include <stdlib.h>

int input;

void func(int x){
    char str[30];
    int c = 0;
    while (1){
	if (x <= 0)	/* Guard1 */
	    break;
	c = c + 1; 	/* IV2 */
	if (c >= 40)	/* Guard2 */
	    break;
	x = x - 1; 	/* IV1 */
    }

    if (c <= 33){		/* overwrite main()'s return addr when input >= 34*/
	str[c] = 0;
    }
}

int main(int argc, char **argv){
    func(input);
    func(input+10);
    return 0;
}
