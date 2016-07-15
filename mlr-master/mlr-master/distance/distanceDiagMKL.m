function D = distanceDiagMKL(W, X)

    [d, n, m] = size(X);

    D = zeros(n);
    for i = 1:m
        D = D + PsdToEdm(X(:,:,i)' * bsxfun(@times, W(:,i), X(:,:,i)));
    end
end
