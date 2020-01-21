// 3 loop summaries in this example.
// 2 on the odd branch and 1 on the even branch

#include <stdio.h>
#include <stdlib.h>

int input;

void func(int x){
    char str[30];
    int c = 0;
    while (1){
	if (x <= 0)	/* Guard 1 on both branch*/ 
	    break;
	if (x % 2 == 0){
	    c = c + 1;
	}
	else{
	    c = c + 2;
	    if (x == 7)	/* Guard 2 only on odd branch*/
		break;
	}
	x = x - 2;
    }

    if (c <= 33){		/* overwrite main()'s return addr when input >= 34*/
	str[c] = 0;
    }
}

int main(int argc, char **argv){
    func(input);
    return 0;
}
