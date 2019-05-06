// A toy example to show the benefit of loopsum

#include <stdio.h>
#include <stdlib.h>

int input;

void func(int x){
	char str[30];
	int c = 0;
	while (1){
		if (x <= 0)	/* Guard */
			break;
		c = c + 1; 	/* IV2 */
		x = x - 1; 	/* IV1 */
	}
	
	if (c <= 40){		/* Loose check, x=46 can trigger seg fault */
		str[c] = 0;
	}
}

int main(int argc, char **argv){
	func(input);
	return 0;
}
